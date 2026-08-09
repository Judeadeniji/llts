const state_mod = @import("state.zig");
const Value = state_mod.Value;
const VMState = state_mod.VMState;

pub fn push(vm: *VMState, v: Value) !void {
    try vm.stack.append(vm.allocator, v);
}

pub fn pop(vm: *VMState) Value {
    return vm.stack.pop().?;
}

pub fn peek(vm: *const VMState, distance: usize) Value {
    const len = vm.stack.items.len;
    return vm.stack.items[len - 1 - distance];
}
