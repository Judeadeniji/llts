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

pub fn callStatic(vm: *VMState, ip: *usize, addr: u32, argc: u8) CallError!void {
    if (vm.frame_count >= state_mod.MAX_FRAMES) return error.TooManyFrames;
    const frame = &vm.frames[vm.frame_count];
    frame.* = .{
        .return_ip = ip.*,
        .base_slot = vm.sp - argc,
        .arg_count = argc,
        .line = vm.current_line,
        .column = vm.current_column,
        .source_index = vm.current_source_index,
        .file = if (vm.current_source_index < vm.chunk.sources.items.len) vm.chunk.sources.items[vm.current_source_index].path else "",
        .heap_watermark = vm.heap_ptr,
        .bytes_watermark = vm.bytes_ptr,
    };
    if (vm.addr_to_func_info.get(addr)) |meta| {
        frame.func_name = meta.name;
        frame.file = meta.file;
        frame.source_index = meta.source_index;
    }
    vm.frame_count += 1;
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
            try callStatic(vm, ip, f.address, argc);
        },
        else => return fail(vm, "Can only call functions"),
    }
}

pub fn doReturn(vm: *VMState, ip: *usize) CallError!bool {
    const result = if (vm.sp > 0) vm.stack_buf[vm.sp - 1] else Value.null;
    if (vm.frame_count == 0) return fail(vm, "Return with no frame");
    vm.frame_count -= 1;
    const frame = &vm.frames[vm.frame_count];
    const ret_ip = frame.return_ip;
    const base = frame.base_slot;
    if (vm.heap_ptr != frame.heap_watermark) vm.heap_ptr = frame.heap_watermark;
    if (frame.bytes_watermark < vm.bytes_ptr) vm.rewindPacked(frame.bytes_watermark);
    frame.deinit();
    if (vm.frame_count == 0) {
        vm.sp = 1;
        vm.stack_buf[0] = result;
        return true;
    }
    vm.stack_buf[base] = result;
    vm.sp = base + 1;
    ip.* = ret_ip;
    return false;
}

pub fn packRest(vm: *VMState, named: u8) CallError!void {
    const frame = vm.frame();
    const total = frame.arg_count;
    const rest_count: u32 = if (total > named) @intCast(total - named) else 0;
    const arr_v = try vm.allocFrameArray(rest_count);
    const a = arr_v.array;
    var i: u32 = 0;
    while (i < rest_count) : (i += 1) {
        const slot = frame.base_slot + named + i;
        vm.arrayElemPtr(a, i).* = vm.stack_buf[slot];
    }
    stack.setTop(vm, frame.base_slot + named);
    try stack.push(vm, arr_v);
}

fn functionNameAt(vm: *VMState, address: u32) []const u8 {
    if (vm.addr_to_func_info.get(address)) |info| return info.name;
    return vm.addr_to_func_name.get(address) orelse "<anonymous>";
}
