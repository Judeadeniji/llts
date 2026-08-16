const out = @import("../io/out.zig");
const color = @import("../io/color.zig");
const diag = @import("diag.zig");

pub fn reportSourceError(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    diag.markEmitted();
    const c_err = color.paint(color.bold ++ color.bright_red);
    const c_arrow = color.paint(color.bold ++ color.bright_cyan);
    const c_num = color.paint(color.blue);
    const c_caret = color.paint(color.bold ++ color.bright_cyan);
    const r = color.r();

    out.printStderr("{s}Error{s}: {s}\n", .{ c_err, r, message });
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

/// Non-fatal warning with source caret. Does not mark `diag.emitted` (fatal-only flag).
pub fn reportSourceWarning(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    const c_warn = color.paint(color.bold ++ color.bright_yellow);
    const c_arrow = color.paint(color.bold ++ color.bright_cyan);
    const c_num = color.paint(color.blue);
    const c_caret = color.paint(color.bold ++ color.bright_cyan);
    const r = color.r();

    out.printStderr("{s}Warning{s}: {s}\n", .{ c_warn, r, message });
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

/// Source diagnostic plus a single stack frame (scan / parse / compile).
pub fn reportSourceErrorWithFrame(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
    frame_name: []const u8,
) void {
    reportSourceError(path, source, line, column, message);
    reportLocationFrameCol(path, line, column, frame_name);
}

pub fn reportLocationFrame(path: []const u8, line: u32, name: []const u8) void {
    reportLocationFrameCol(path, line, 1, name);
}

pub fn reportLocationFrameCol(path: []const u8, line: u32, column: u32, name: []const u8) void {
    diag.markEmitted();
    const c_dim = color.paint(color.dim);
    const c_name = color.paint(color.cyan);
    const r = color.r();
    out.printStderr("    {s}at{s} {s}{s}{s} ({s}:{d}:{d})\n", .{ c_dim, r, c_name, name, r, path, line, column });
}

pub fn reportCompileMessage(message: []const u8) void {
    diag.markEmitted();
    const c_err = color.paint(color.bold ++ color.bright_red);
    const r = color.r();
    out.printStderr("{s}Error{s}: {s}\n", .{ c_err, r, message });
}

/// Location-less compile failure; keeps `CompileError:` prefix for existing tests.
pub fn reportCompileError(message: []const u8) void {
    diag.markEmitted();
    const c_err = color.paint(color.bold ++ color.bright_red);
    const r = color.r();
    out.printStderr("{s}CompileError{s}: {s}\n", .{ c_err, r, message });
}
