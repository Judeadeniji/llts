const state_mod = @import("../vm/state.zig");
const report = @import("report.zig");
const stack_trace = @import("stack_trace.zig");

/// Print runtime diagnostic (source context + stack) then return RuntimeError.
pub fn runtimeFail(vm: *state_mod.VMState, message: []const u8) error{RuntimeError} {
    const file = blk: {
        if (vm.frames.items.len > 0) {
            const f = vm.frames.items[vm.frames.items.len - 1].file;
            if (f.len > 0) break :blk f;
        }
        if (vm.chunk.file.len > 0) break :blk vm.chunk.file;
        break :blk "<anonymous>";
    };
    const source = vm.sourceForFile(file);
    const line = vm.current_line;
    const column = vm.current_column;
    if (line > 0) {
        report.reportSourceError(file, source, line, column, message);
    } else {
        report.reportRuntimeError(message);
    }
    stack_trace.reportStackTrace(vm.frames.items);
    return error.RuntimeError;
}
