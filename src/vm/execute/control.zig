const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const VMState = state_mod.VMState;

pub fn jumpIfFalse(vm: *VMState, ip: *usize, offset: u16) void {
    if (!stack.peek(vm, 0).isTruthy()) ip.* += offset;
}

pub fn jump(ip: *usize, offset: u16) void {
    ip.* += offset;
}

pub fn loop(ip: *usize, offset: u16) void {
    ip.* -= offset;
}
