const state_mod = @import("state.zig");
const Value = state_mod.Value;
const VMState = state_mod.VMState;

pub inline fn push(vm: *VMState, v: Value) !void {
    if (vm.sp >= state_mod.STACK_MAX) return error.OutOfMemory;
    vm.stack_buf[vm.sp] = v;
    vm.sp += 1;
}

pub inline fn pop(vm: *VMState) Value {
    vm.sp -= 1;
    return vm.stack_buf[vm.sp];
}

pub inline fn peek(vm: *const VMState, distance: usize) Value {
    return vm.stack_buf[vm.sp - 1 - distance];
}

pub inline fn setTop(vm: *VMState, new_sp: usize) void {
    vm.sp = new_sp;
}

pub inline fn depth(vm: *const VMState) usize {
    return vm.sp;
}

pub inline fn at(vm: *VMState, idx: usize) *Value {
    return &vm.stack_buf[idx];
}

pub inline fn slice(vm: *VMState, start: usize) []Value {
    return vm.stack_buf[start..vm.sp];
}
