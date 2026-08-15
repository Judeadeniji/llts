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
    return &vm.frames.items[vm.frames.items.len - 1];
}

fn resolveName(vm: *VMState, v: Value) ?[]const u8 {
    return switch (v) {
        .name => |idx| vm.chunk.stringAt(idx),
        else => null,
    };
}

pub fn getLocal(vm: *VMState, slot: u8) VarError!void {
    const f = frame(vm);
    const idx = f.base_slot + slot;
    const v = if (idx < stack.depth(vm)) vm.stack_buf[idx] else Value.null;
    try stack.push(vm, v);
}

pub fn setLocal(vm: *VMState, slot: u8) VarError!void {
    const f = frame(vm);
    if (f.const_slots.contains(slot)) return fail(vm, "Cannot assign to @const binding");
    const val = stack.peek(vm, 0);
    const idx = f.base_slot + slot;
    while (stack.depth(vm) <= idx) try stack.push(vm, .null);
    vm.stack_buf[idx] = val;
}

pub fn getGlobal(vm: *VMState, slot: u16) VarError!void {
    const g = vm.getGlobalSlot(slot) orelse {
        var buf: [256]u8 = undefined;
        const name = if (slot < vm.chunk.global_names.items.len) vm.chunk.global_names.items[slot] else "?";
        const msg = std.fmt.bufPrint(&buf, "Undefined variable '{s}'", .{name}) catch "Undefined variable";
        return fail(vm, msg);
    };
    try stack.push(vm, g);
}

pub fn setGlobal(vm: *VMState, slot: u16) VarError!void {
    try vm.setGlobalSlot(slot, stack.peek(vm, 0));
}

pub fn getFunction(vm: *VMState, const_idx: u16) VarError!void {
    const name_val = vm.chunk.constants.items[const_idx];
    const name = resolveName(vm, name_val) orelse return fail(vm, "Bad function name");
    const f = vm.chunk.functions.get(name) orelse return fail(vm, "Undefined function");
    try stack.push(vm, .{ .function = f });
}
