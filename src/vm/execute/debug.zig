const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const VMState = state_mod.VMState;

pub fn line(vm: *VMState, line_no: u16) void {
    vm.current_line = line_no;
    vm.frames.items[vm.frames.items.len - 1].line = line_no;
}

pub fn markConst(vm: *VMState, slot: u8) !void {
    try vm.frames.items[vm.frames.items.len - 1].const_slots.put(slot, {});
}

pub fn assertType(vm: *VMState, tag: u8) !void {
    _ = vm;
    _ = tag;
    // Full check in typecheck phase; peek-only no-op for unknown tags for now
}
