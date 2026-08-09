const std = @import("std");
const state_mod = @import("../vm/state.zig");
const report = @import("report.zig");
const stack_trace = @import("stack_trace.zig");

/// Print runtime diagnostic (source context + stack) then return RuntimeError.
pub fn runtimeFail(vm: *state_mod.VMState, message: []const u8) error{RuntimeError} {
    const file = if (vm.chunk.file.len > 0) vm.chunk.file else "<anonymous>";
    const source = vm.chunk.source;
    const line = if (vm.current_line > 0) vm.current_line else 1;
    report.reportSourceError(file, source, line, 1, message);
    stack_trace.reportStackTrace(vm.frames.items, file, line);
    return error.RuntimeError;
}
