const out = @import("../io/out.zig");
const color = @import("../io/color.zig");
const diag = @import("diag.zig");
const collector = @import("collector.zig");
const render = @import("render.zig");

/// Returns the active collector, or null if diagnostics should print directly.
fn active() ?*collector.Collector {
    return collector.getActive();
}

/// Shared source diagnostic path. When a collector is active, records a
/// diagnostic instead of printing; otherwise renders it immediately.
fn emitSource(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
    mark_emitted: bool,
    severity: render.Severity,
) void {
    if (active()) |c| {
        _ = c.add(path, source, line, column, message, severity);
        return;
    }
    if (mark_emitted) diag.markEmitted();
    render.printDiagnostic(path, source, line, column, message, severity, &.{});
}

pub fn reportSourceError(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    emitSource(path, source, line, column, message, true, .err);
}

/// Non-fatal warning with source excerpt. Does not mark `diag.emitted`
/// (fatal-only flag).
pub fn reportSourceWarning(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    emitSource(path, source, line, column, message, false, .warning);
}

/// Source diagnostic plus a single stack frame (scan / parse / compile).
pub fn reportSourceErrorWithFrame(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
    frame_name: []const u8,
) void {
    if (active()) |c| {
        _ = c.add(path, source, line, column, message, .err);
        c.addFrame(path, line, column, frame_name);
        return;
    }
    diag.markEmitted();
    const frames = [_]render.Frame{.{
        .path = path,
        .line = line,
        .column = column,
        .name = frame_name,
    }};
    render.printDiagnostic(path, source, line, column, message, .err, &frames);
}

pub fn reportLocationFrame(path: []const u8, line: u32, name: []const u8) void {
    reportLocationFrameCol(path, line, 1, name);
}

pub fn reportLocationFrameCol(path: []const u8, line: u32, column: u32, name: []const u8) void {
    if (active()) |c| {
        c.addFrame(path, line, column, name);
        return;
    }
    diag.markEmitted();
    const c_dim = color.paint(color.dim);
    const c_name = color.paint(color.cyan);
    const r = color.r();
    out.printStderr("    {s}at{s} {s}{s}{s} ({s}:{d}:{d})\n", .{ c_dim, r, c_name, name, r, path, line, column });
}

pub fn reportCompileMessage(message: []const u8) void {
    if (active()) |c| {
        _ = c.add("", "", 1, 1, message, .err);
        return;
    }
    diag.markEmitted();
    render.printDiagnostic("", "", 1, 1, message, .err, &.{});
}

pub fn reportRuntimeError(message: []const u8) void {
    if (active()) |c| {
        _ = c.add("", "", 1, 1, message, .err);
        return;
    }
    diag.markEmitted();
    render.printDiagnostic("", "", 1, 1, message, .err, &.{});
}
