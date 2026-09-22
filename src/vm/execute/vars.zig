const std = @import("std");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const runtime = @import("../../errors/runtime.zig");
const VMState = state_mod.VMState;
const Value = state_mod.Value;

pub const VarError = error{ RuntimeError, ConstMutation, OutOfMemory };

fn fail(vm: *VMState, msg: []const u8) VarError {
    return runtime.runtimeFail(vm, msg);
}

fn frame(vm: *VMState) *state_mod.CallFrame {
    return vm.frame();
}

fn resolveName(vm: *VMState, v: Value) ?[]const u8 {
    return switch (v) {
        .name => |idx| vm.chunk.stringAt(idx),
        else => null,
    };
}

pub inline fn getLocal(vm: *VMState, slot: u8) VarError!void {
    const f = vm.frame();
    const idx = f.base_slot + slot;
    if (idx < vm.sp and vm.sp < state_mod.STACK_MAX) {
        vm.stack_buf[vm.sp] = vm.stack_buf[idx];
        vm.sp += 1;
        return;
    }
    const v = if (idx < stack.depth(vm)) vm.stack_buf[idx] else Value.null;
    try stack.push(vm, v);
}

pub inline fn setLocal(vm: *VMState, slot: u8) VarError!void {
    const f = vm.frame();
    if (f.isConst(slot)) return fail(vm, "Cannot assign to @const binding");
    const idx = f.base_slot + slot;
    if (idx < vm.sp and vm.sp > 0) {
        vm.stack_buf[idx] = vm.stack_buf[vm.sp - 1];
        return;
    }
    const val = stack.peek(vm, 0);
    while (stack.depth(vm) <= idx) try stack.push(vm, .null);
    vm.stack_buf[idx] = val;
}

pub inline fn getGlobal(vm: *VMState, slot: u16) VarError!void {
    if (slot < vm.global_count and vm.sp < state_mod.STACK_MAX) {
        vm.stack_buf[vm.sp] = vm.global_values[slot];
        vm.sp += 1;
        return;
    }
    const g = vm.getGlobalSlot(slot) orelse {
        var buf: [256]u8 = undefined;
        const name = if (slot < vm.chunk.global_names.items.len) vm.chunk.global_names.items[slot] else "?";
        const msg = std.fmt.bufPrint(&buf, "Undefined variable '{s}'", .{name}) catch "Undefined variable";
        return fail(vm, msg);
    };
    try stack.push(vm, g);
}

pub inline fn setGlobal(vm: *VMState, slot: u16) VarError!void {
    if (slot < vm.global_count and vm.sp > 0) {
        vm.global_values[slot] = vm.stack_buf[vm.sp - 1];
        return;
    }
    try vm.setGlobalSlot(slot, stack.peek(vm, 0));
}

pub fn getFunction(vm: *VMState, const_idx: u16) VarError!void {
    const name_val = vm.chunk.constants.items[const_idx];
    const name = resolveName(vm, name_val) orelse return fail(vm, "Bad function name");
    const f = vm.chunk.functions.getPtr(name) orelse return fail(vm, "Undefined function");
    try stack.push(vm, .{ .function = f });
}
