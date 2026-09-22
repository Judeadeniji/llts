const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const runtime = @import("../../errors/runtime.zig");
const VMState = state_mod.VMState;
const Value = state_mod.Value;

pub fn jumpIfFalse(vm: *VMState, ip: *usize, offset: u16) void {
    if (!stack.peek(vm, 0).isTruthy()) ip.* += offset;
}

pub fn jump(ip: *usize, offset: u16) void {
    ip.* += offset;
}

pub fn loop(ip: *usize, offset: u16) void {
    ip.* -= offset;
}

fn frame(vm: *VMState) *state_mod.CallFrame {
    return vm.frame();
}

fn localInt(vm: *VMState, slot: u8) !i64 {
    const f = frame(vm);
    const idx = f.base_slot + slot;
    if (idx >= stack.depth(vm)) return error.TypeError;
    return switch (vm.stack_buf[idx]) {
        .i64 => |n| n,
        else => error.TypeError,
    };
}

fn setLocalInt(vm: *VMState, slot: u8, n: i64) !void {
    const f = frame(vm);
    const idx = f.base_slot + slot;
    while (stack.depth(vm) <= idx) try stack.push(vm, .null);
    vm.stack_buf[idx] = .{ .i64 = n };
}

/// If local[i] >= local[end], jump forward by `skip` (to after FOR_LOOP); else fall into body.
pub inline fn forPrep(vm: *VMState, ip: *usize, i_slot: u8, end_slot: u8, skip: u16) !void {
    const f = vm.frame();
    const i_idx = f.base_slot + i_slot;
    const end_idx = f.base_slot + end_slot;
    if (i_idx < vm.sp and end_idx < vm.sp) {
        const i_val = vm.stack_buf[i_idx];
        const end_val = vm.stack_buf[end_idx];
        if (i_val == .i64 and end_val == .i64) {
            if (i_val.i64 >= end_val.i64) ip.* += skip;
            return;
        }
    }
    const i = try localInt(vm, i_slot);
    const end = try localInt(vm, end_slot);
    if (i >= end) ip.* += skip;
}

/// local[i] += 1; if local[i] < local[end], jump back by `back`; else fall through.
pub inline fn forLoop(vm: *VMState, ip: *usize, i_slot: u8, end_slot: u8, back: u16) !void {
    const f = vm.frame();
    const i_idx = f.base_slot + i_slot;
    const end_idx = f.base_slot + end_slot;
    if (i_idx < vm.sp and end_idx < vm.sp) {
        const i_val = vm.stack_buf[i_idx];
        const end_val = vm.stack_buf[end_idx];
        if (i_val == .i64 and end_val == .i64) {
            const next = i_val.i64 +% 1;
            vm.stack_buf[i_idx] = .{ .i64 = next };
            if (next < end_val.i64) ip.* -= back;
            return;
        }
    }
    const i = try localInt(vm, i_slot);
    const end = try localInt(vm, end_slot);
    const next = i +% 1;
    try setLocalInt(vm, i_slot, next);
    if (next < end) ip.* -= back;
}
