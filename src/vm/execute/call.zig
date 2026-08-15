const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const value = @import("../../bytecode/value.zig");
const std = @import("std");
const runtime = @import("../../errors/runtime.zig");
const VMState = state_mod.VMState;
const Value = value.Value;
const CallFrame = state_mod.CallFrame;
const MAX_FRAMES = state_mod.MAX_FRAMES;

pub const CallError = error{ RuntimeError, TooManyFrames, TypeError, ArityError, OutOfMemory };

fn fail(vm: *VMState, msg: []const u8) CallError {
    return runtime.runtimeFail(vm, msg);
}

pub fn callStatic(vm: *VMState, ip: *usize, addr: u16, argc: u8) CallError!void {
    if (vm.frames.items.len >= MAX_FRAMES) return error.TooManyFrames;
    var frame = CallFrame.init(vm.allocator);
    frame.return_ip = ip.*;
    frame.base_slot = stack.depth(vm) - argc;
    frame.arg_count = argc;
    frame.func_name = functionNameAt(vm, addr);
    frame.line = vm.current_line;
    frame.column = vm.current_column;
    frame.source_index = vm.current_source_index;
    frame.file = vm.chunk.sourceAt(vm.current_source_index).path;
    if (vm.chunk.functions.get(frame.func_name)) |fn_info| {
        frame.source_index = fn_info.source_index;
        frame.file = vm.chunk.sourceAt(fn_info.source_index).path;
    }
    frame.heap_watermark = vm.heap_ptr;
    try vm.frames.append(vm.allocator, frame);
    ip.* = addr;
}

pub fn callDynamic(vm: *VMState, ip: *usize, argc: u8) CallError!void {
    const depth = stack.depth(vm);
    const callee_idx = depth - argc - 1;
    if (callee_idx >= depth) return fail(vm, "Stack underflow on call");
    const callee = vm.stack_buf[callee_idx];
    switch (callee) {
        .native => |n| {
            const args = stack.slice(vm, callee_idx + 1);
            if (n.arity >= 0 and args.len != @as(usize, @intCast(n.arity))) {
                return fail(vm, "Wrong arity for native");
            }
            const result = n.func(vm, args) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Native '{s}' failed: {s}", .{ n.name, @errorName(err) }) catch "native call failed";
                return fail(vm, msg);
            };
            stack.setTop(vm, callee_idx);
            try stack.push(vm, result);
        },
        .function => |f| {
            var i: usize = 0;
            while (i < argc) : (i += 1) {
                vm.stack_buf[callee_idx + i] = vm.stack_buf[callee_idx + 1 + i];
            }
            stack.setTop(vm, callee_idx + argc);
            try callStatic(vm, ip, @intCast(f.address), argc);
        },
        else => return fail(vm, "Can only call functions"),
    }
}

pub fn doReturn(vm: *VMState, ip: *usize) CallError!bool {
    const result = if (stack.depth(vm) > 0) stack.pop(vm) else Value.null;
    var frame = vm.frames.pop() orelse return fail(vm, "Return with no frame");
    const ret_ip = frame.return_ip;
    const base = frame.base_slot;
    vm.heap_ptr = frame.heap_watermark;
    frame.deinit();
    if (vm.frames.items.len == 0) {
        stack.setTop(vm, 0);
        try stack.push(vm, result);
        return true;
    }
    stack.setTop(vm, base);
    try stack.push(vm, result);
    ip.* = ret_ip;
    return false;
}

pub fn packRest(vm: *VMState, named: u8) CallError!void {
    const frame = &vm.frames.items[vm.frames.items.len - 1];
    const total = frame.arg_count;
    const rest_count: i32 = if (total > named) @intCast(total - named) else 0;
    const base = try vm.allocSlots(rest_count + 1);
    vm.slot(base).* = .{ .int = rest_count };
    var i: i32 = 0;
    while (i < rest_count) : (i += 1) {
        const slot = frame.base_slot + named + @as(usize, @intCast(i));
        vm.slot(base + 1 + i).* = vm.stack_buf[slot];
    }
    stack.setTop(vm, frame.base_slot + named);
    try stack.push(vm, .{ .ptr = base + 1 });
}

fn functionNameAt(vm: *VMState, address: u16) []const u8 {
    var it = vm.chunk.functions.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.address == address) return e.key_ptr.*;
    }
    return "<anonymous>";
}
