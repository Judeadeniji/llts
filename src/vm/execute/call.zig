const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const CallFrame = state_mod.CallFrame;
const MAX_FRAMES = state_mod.MAX_FRAMES;

pub const CallError = error{ RuntimeError, TooManyFrames, TypeError, ArityError, OutOfMemory };

fn fail(msg: []const u8) CallError {
    @import("std").debug.print("RuntimeError: {s}\n", .{msg});
    return error.RuntimeError;
}

pub fn callStatic(vm: *VMState, ip: *usize, addr: u16, argc: u8) CallError!void {
    if (vm.frames.items.len >= MAX_FRAMES) return error.TooManyFrames;
    var frame = CallFrame.init(vm.allocator);
    frame.return_ip = ip.*;
    frame.base_slot = vm.stack.items.len - argc;
    frame.arg_count = argc;
    frame.func_name = functionNameAt(vm, addr);
    try vm.frames.append(vm.allocator, frame);
    ip.* = addr;
}

pub fn callDynamic(vm: *VMState, ip: *usize, argc: u8) CallError!void {
    // Callee is below args: stack = [… callee arg0…argN]
    const callee_idx = vm.stack.items.len - argc - 1;
    if (callee_idx >= vm.stack.items.len) return fail("Stack underflow on call");
    const callee = vm.stack.items[callee_idx];
    switch (callee) {
        .native => |n| {
            const args = vm.stack.items[callee_idx + 1 ..];
            if (n.arity >= 0 and args.len != @as(usize, @intCast(n.arity))) {
                return fail("Wrong arity for native");
            }
            const result = n.func(vm, args) catch return fail("native call failed");
            vm.stack.shrinkRetainingCapacity(callee_idx);
            try stack.push(vm, result);
        },
        .function => |f| {
            // Slide args over callee
            var i: usize = 0;
            while (i < argc) : (i += 1) {
                vm.stack.items[callee_idx + i] = vm.stack.items[callee_idx + 1 + i];
            }
            vm.stack.shrinkRetainingCapacity(callee_idx + argc);
            try callStatic(vm, ip, @intCast(f.address), argc);
        },
        else => return fail("Can only call functions"),
    }
}

pub fn doReturn(vm: *VMState, ip: *usize) CallError!bool {
    // Returns true if VM should halt (no frames left)
    const result = if (vm.stack.items.len > 0) stack.pop(vm) else Value.null;
    var frame = vm.frames.pop() orelse return fail("Return with no frame");
    const ret_ip = frame.return_ip;
    const base = frame.base_slot;
    frame.deinit();
    if (vm.frames.items.len == 0) {
        vm.stack.shrinkRetainingCapacity(0);
        try stack.push(vm, result);
        return true;
    }
    vm.stack.shrinkRetainingCapacity(base);
    try stack.push(vm, result);
    ip.* = ret_ip;
    return false;
}

pub fn packRest(vm: *VMState, named: u8) CallError!void {
    const frame = &vm.frames.items[vm.frames.items.len - 1];
    const total = frame.arg_count;
    const rest_count: i32 = if (total > named) @intCast(total - named) else 0;
    const base = try vm.allocSlots(rest_count + 1);
    vm.memory[@intCast(base)] = rest_count;
    var i: i32 = 0;
    while (i < rest_count) : (i += 1) {
        const slot = frame.base_slot + named + @as(usize, @intCast(i));
        const v = vm.stack.items[slot];
        vm.memory[@intCast(base + 1 + i)] = switch (v) {
            .int => |n| n,
            .ptr => |p| p,
            .bool => |b| @intFromBool(b),
            else => 0,
        };
    }
    // Truncate extras and push rest array ptr
    vm.stack.shrinkRetainingCapacity(frame.base_slot + named);
    try stack.push(vm, .{ .ptr = base + 1 });
}

fn functionNameAt(vm: *VMState, address: u16) []const u8 {
    var it = vm.chunk.functions.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.address == address) return e.key_ptr.*;
    }
    return "<script>";
}
