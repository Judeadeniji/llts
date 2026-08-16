const std = @import("std");
const report = @import("report.zig");
const state_mod = @import("../compiler/state.zig");

const CompilerState = state_mod.CompilerState;

fn sourceFor(state: *CompilerState, file_path: []const u8) []const u8 {
    for (state.chunk.sources.items) |s| {
        if (std.mem.eql(u8, s.path, file_path)) return s.text;
    }
    return state.chunk.source;
}

/// Walk persisted import edges from the faulting file outward to the entrypoint.
pub fn reportImportChain(state: *CompilerState, leaf_path: []const u8) void {
    var path = leaf_path;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const frame = state.import_from.get(path) orelse break;
        var name_buf: [256]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "@import(\"{s}\")", .{frame.import_path}) catch "@import";
        report.reportLocationFrameCol(frame.path, frame.line, frame.column, name);
        path = frame.path;
    }
}

pub fn compileFail(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) error{CompileError} {
    report.reportSourceErrorWithFrame(path, source, line, column, message, "<compile>");
    return error.CompileError;
}

/// Prefer this for all compiler failures — uses the last noted AST location on `state`.
pub fn compileFailFmt(state: *CompilerState, comptime fmt: []const u8, args: anytype) error{CompileError} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        return compileFailFromState(state, fmt);
    };
    return compileFailFromState(state, msg);
}

pub fn compileFailMsg(state: *CompilerState, message: []const u8) error{CompileError} {
    return compileFailFromState(state, message);
}

fn compileFailFromState(state: *CompilerState, message: []const u8) error{CompileError} {
    const path = if (state.diag_path.len > 0) state.diag_path else state.chunk.file;
    const line = if (state.diag_line > 0) state.diag_line else 1;
    const column = if (state.diag_column > 0) state.diag_column else 1;
    report.reportSourceErrorWithFrame(path, sourceFor(state, path), line, column, message, "<compile>");
    reportImportChain(state, path);
    return error.CompileError;
}

/// Rich compile failure from an explicit AST location (still prints import chain).
pub fn compileFailAt(
    state: *CompilerState,
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    comptime fmt: []const u8,
    args: anytype,
) error{CompileError} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    report.reportSourceErrorWithFrame(path, source, line, column, msg, "<compile>");
    reportImportChain(state, path);
    return error.CompileError;
}

/// Non-fatal compile warning at an explicit AST location.
pub fn compileWarnAt(
    _: *CompilerState,
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    report.reportSourceWarning(path, source, line, column, msg);
}

/// Non-fatal warning using the last noted AST location on `state`.
pub fn compileWarnFmt(state: *CompilerState, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    const path = if (state.diag_path.len > 0) state.diag_path else state.chunk.file;
    const line = if (state.diag_line > 0) state.diag_line else 1;
    const column = if (state.diag_column > 0) state.diag_column else 1;
    report.reportSourceWarning(path, sourceFor(state, path), line, column, msg);
}
