const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const VMState = state_mod.VMState;
const Value = state_mod.Value;

pub const VarError = error{ RuntimeError, ConstMutation, OutOfMemory };

fn fail(msg: []const u8) VarError {
    @import("std").debug.print("RuntimeError: {s}\n", .{msg});
    return error.RuntimeError;
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
    const v = if (idx < vm.stack.items.len) vm.stack.items[idx] else Value.null;
    try stack.push(vm, v);
}

pub fn setLocal(vm: *VMState, slot: u8) VarError!void {
    const f = frame(vm);
    if (f.const_slots.contains(slot)) return fail("Cannot assign to @const binding");
    const val = stack.peek(vm, 0);
    const idx = f.base_slot + slot;
    while (vm.stack.items.len <= idx) try stack.push(vm, .null);
    vm.stack.items[idx] = val;
}

pub fn getGlobal(vm: *VMState, const_idx: u8) VarError!void {
    const name_val = vm.chunk.constants.items[const_idx];
    const name = resolveName(vm, name_val) orelse return fail("Bad global name");
    const g = vm.globals.get(name) orelse return fail("Undefined variable");
    try stack.push(vm, g);
}

pub fn setGlobal(vm: *VMState, const_idx: u8) VarError!void {
    const name_val = vm.chunk.constants.items[const_idx];
    const name = resolveName(vm, name_val) orelse return fail("Bad global name");
    try vm.globals.put(name, stack.peek(vm, 0));
}

pub fn getFunction(vm: *VMState, const_idx: u8) VarError!void {
    const name_val = vm.chunk.constants.items[const_idx];
    const name = resolveName(vm, name_val) orelse return fail("Bad function name");
    const f = vm.chunk.functions.get(name) orelse return fail("Undefined function");
    try stack.push(vm, .{ .function = f });
}
