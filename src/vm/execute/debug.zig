const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const VMState = state_mod.VMState;

pub fn line(vm: *VMState, line_no: u16, column: u16) void {
    vm.current_line = line_no;
    vm.current_column = if (column == 0) 1 else column;
    if (vm.frame_count > 0) {
        const f = vm.frame();
        f.line = vm.current_line;
        f.column = vm.current_column;
    }
}

pub fn source(vm: *VMState, idx: u16) void {
    vm.current_source_index = idx;
    const sf = vm.chunk.sourceAt(idx);
    if (vm.frame_count > 0) {
        const f = vm.frame();
        f.source_index = idx;
        f.file = sf.path;
    }
}

pub fn markConst(vm: *VMState, slot: u8) !void {
    vm.frame().markConst(slot);
}

pub fn assertType(vm: *VMState, tag: u8) !void {
    _ = vm;
    _ = tag;
    // Full check in typecheck phase; peek-only no-op for unknown tags for now
}
