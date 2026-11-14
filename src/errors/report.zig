const out = @import("../io/out.zig");
const color = @import("../io/color.zig");
const diag = @import("diag.zig");
const collector = @import("collector.zig");

/// Returns the active collector, or null if diagnostics should print directly.
fn active() ?*collector.Collector {
    return collector.getActive();
}

/// Shared source caret rendering. When a collector is active, records a
/// diagnostic instead of printing; otherwise prints as today.
fn renderSource(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    label: []const u8,
    label_color: []const u8,
    message: []const u8,
    mark_emitted: bool,
    severity: collector.Severity,
) void {
    if (active()) |c| {
        _ = c.add(path, source, line, column, message, severity);
        return;
    }
    if (mark_emitted) diag.markEmitted();
    const c_err = color.paint(label_color);
    const c_arrow = color.paint(color.bold ++ color.bright_cyan);
    const c_num = color.paint(color.blue);
    const c_caret = color.paint(color.bold ++ color.bright_cyan);
    const r = color.r();

    out.printStderr("{s}{s}{s}: {s}\n", .{ c_err, r, label, message });
    out.printStderr("  {s}-->{s} {s}:{d}:{d}\n", .{ c_arrow, r, path, line, column });

    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (current == line) {
                const line_src = source[start..i];
                out.printStderr("   {s}{d}{s} | {s}\n", .{ c_num, line, r, line_src });
                out.printStderr("     | ", .{});
                var c: u32 = 1;
                const col = if (column == 0) 1 else column;
                while (c < col) : (c += 1) out.printStderr(" ", .{});
                out.printStderr("{s}^{s}\n", .{ c_caret, r });
                break;
            }
            current += 1;
            start = i + 1;
        }
    }
}

pub fn reportSourceError(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    renderSource(path, source, line, column, "Error", color.bold ++ color.bright_red, message, true, .err);
}

pub fn reportSourceWarning(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    renderSource(path, source, line, column, "Warning", color.bold ++ color.bright_yellow, message, false, .warning);
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
    reportSourceError(path, source, line, column, message);
    reportLocationFrameCol(path, line, column, frame_name);
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
    const c_err = color.paint(color.bold ++ color.bright_red);
    const r = color.r();
    out.printStderr("{s}Error{s}: {s}\n", .{ c_err, r, message });
}

pub fn reportRuntimeError(message: []const u8) void {
    if (active()) |c| {
        _ = c.add("", "", 1, 1, message, .err);
        return;
    }
    diag.markEmitted();
    const c_err = color.paint(color.bold ++ color.bright_red);
    const r = color.r();
    out.printStderr("{s}Error{s}: {s}\n", .{ c_err, r, message });
}
