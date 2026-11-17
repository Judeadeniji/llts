//! Diagnostic rendering in the `tsc --pretty` / `tsrs` shape:
//!
//! ```text
//! app.lls:4:9 - error: type 'const []u8' is not assignable to 'i64'
//!
//! 4   $name: i64 = "hello";
//!     ~~~~~~~~~
//!
//! Found 1 error in the same file, starting at: app.lls:4.
//! ```
//!
//! Every compile diagnostic goes through here, whether it was recorded in a
//! collector or printed immediately, so the two paths cannot drift.

const std = @import("std");
const out = @import("../io/out.zig");
const color = @import("../io/color.zig");

pub const Severity = enum {
    err,
    warning,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }

    fn colorCode(self: Severity) []const u8 {
        return switch (self) {
            .err => color.bold ++ color.bright_red,
            .warning => color.bold ++ color.bright_yellow,
        };
    }
};

pub const Frame = struct {
    path: []const u8,
    line: u32,
    column: u32,
    name: []const u8,
};

/// Extra context attached to a diagnostic, pointing at a second source site:
/// where a function was declared, what type it was declared to return, and so
/// on. Rendered like Rust's `note:` labels, underneath the main excerpt.
pub const Note = struct {
    path: []const u8 = "",
    source: []const u8 = "",
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8,
};

/// Source excerpt plus caret for one diagnostic, then any notes and frames
/// stacked underneath it. Ends with a blank line so blocks stay separated.
pub fn printDiagnostic(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
    severity: Severity,
    frames: []const Frame,
    notes: []const Note,
) void {
    const c_sev = color.paint(severity.colorCode());
    const c_path = color.paint(color.bright_cyan);
    const c_num = color.paint(color.yellow);
    const c_dim = color.paint(color.dim);
    const r = color.r();

    if (path.len == 0) {
        // No location (compile/runtime messages that carry no source site).
        out.printStderr("{s}{s}{s}: {s}\n\n", .{ c_sev, severity.label(), r, message });
        return;
    }

    out.printStderr("{s}{s}{s}:{s}{d}{s}:{s}{d}{s} - {s}{s}{s}: {s}\n\n", .{
        c_path, path, r, c_num, line, r, c_num, column, r, c_sev, severity.label(), r, message,
    });

    printExcerpt(source, line, column);

    for (notes) |n| {
        printNote(n);
    }

    for (frames) |f| {
        // Synthetic frames such as `<compile>` repeat the caret location and
        // only add noise; real frames (import chains, `@asm`) are kept.
        if (f.name.len > 1 and f.name[0] == '<') continue;
        if (f.path.len == 0) {
            out.printStderr("    {s}at{s} {s}\n", .{ c_dim, r, f.name });
        } else {
            out.printStderr("    {s}at{s} {s}{s}{s} ({s}:{d}:{d})\n", .{
                c_dim, r, c_path, f.name, r, f.path, f.line, f.column,
            });
        }
    }

    out.printStderr("\n", .{});
}

/// Render a `note:` block with its own source excerpt, indented so it reads
/// as context belonging to the diagnostic above it.
pub fn printNote(note: Note) void {
    const c_note = color.paint(color.bold ++ color.bright_cyan);
    const r = color.r();
    out.printStderr("    {s}note{s}: {s}\n", .{ c_note, r, note.message });
    printExcerpt(note.source, note.line, note.column);
}

/// Print a numbered source line with a caret under `column`.
fn printExcerpt(source: []const u8, line: u32, column: u32) void {
    const src_line = findLine(source, line) orelse return;
    const c_mark = color.paint(color.bright_cyan);
    const c_gutter = color.paint(color.reverse);
    const r = color.r();

    var width_buf: [12]u8 = undefined;
    const num = std.fmt.bufPrint(&width_buf, "{d}", .{line}) catch "?";
    const gutter_width = num.len;

    out.printStderr("{s}{s}{s} {s}\n", .{ c_gutter, num, r, src_line });

    // `column` is a byte offset into the line. Tabs and multi-byte
    // characters take up more than one terminal cell, so the marker is
    // positioned by the *display width* of the prefix, and repeated for
    // the display width of the underlined bytes.
    const start = byteOffset(src_line, column);
    const span = highlightSpan(src_line, start);
    const prefix_width = displayWidth(src_line[0..start]);
    const mark_width = @max(displayWidth(src_line[start .. start + span]), 1);

    out.printStderr("{s}", .{c_gutter});
    var gutter_pad: usize = 0;
    while (gutter_pad < gutter_width) : (gutter_pad += 1) out.printStderr(" ", .{});
    out.printStderr("{s} ", .{r});
    var pad: usize = 0;
    while (pad < prefix_width) : (pad += 1) out.printStderr(" ", .{});
    out.printStderr("{s}", .{c_mark});
    var mark: usize = 0;
    while (mark < mark_width) : (mark += 1) out.printStderr("~", .{});
    out.printStderr("{s}\n", .{r});
}

/// Total line count of a diagnostic block: one heading, a blank line, the
/// excerpt (when the line exists), frames, and a trailing blank line.
pub fn printSummary(error_count: usize, files: []const []const u8, first_path: []const u8, first_line: u32, suppressed: usize) void {
    if (error_count > 0) {
        const c_dim = color.paint(color.dim);
        const c_path = color.paint(color.bright_cyan);
        const r = color.r();
        if (files.len == 1 and first_path.len > 0) {
            out.printStderr("Found {d} error{s} in the same file, starting at: {s}{s}{s}{s}:{d}{s}.\n", .{
                error_count,
                if (error_count == 1) "" else "s",
                c_path,
                first_path,
                r,
                c_dim,
                first_line,
                r,
            });
        } else if (files.len > 1) {
            out.printStderr("Found {d} error{s} in {d} file{s}.\n", .{
                error_count,
                if (error_count == 1) "" else "s",
                files.len,
                if (files.len == 1) "" else "s",
            });
        } else {
            out.printStderr("Found {d} error{s}.\n", .{
                error_count,
                if (error_count == 1) "" else "s",
            });
        }
    }
    if (suppressed > 0) {
        const c_dim = color.paint(color.dim);
        const r = color.r();
        out.printStderr("{s}{d} further error{s} suppressed (--max-errors limit).{s}\n", .{
            c_dim,
            suppressed,
            if (suppressed == 1) "" else "s",
            r,
        });
    }
}

/// The text of `line` (1-based) with the trailing `\r` stripped, or null when
/// the line is outside the source.
fn findLine(source: []const u8, line: u32) ?[]const u8 {
    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (current == line) {
                var end = i;
                if (end > start and source[end - 1] == '\r') end -= 1;
                return source[start..end];
            }
            current += 1;
            start = i + 1;
        }
    }
    return null;
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '$';
}

/// Byte offset of a 1-based column, clamped to the line.
fn byteOffset(src_line: []const u8, column: u32) usize {
    const start: usize = if (column == 0) 0 else column - 1;
    return @min(start, src_line.len);
}

/// Underline the token starting at byte `start`, the way `tsc` underlines an
/// expression: a whole quoted string, an identifier-ish name, or a single
/// character for anything else.
fn highlightSpan(src_line: []const u8, start: usize) usize {
    if (start >= src_line.len) return 1;
    const ch = src_line[start];
    if (ch == '"' or ch == '\'') {
        var end = start + 1;
        while (end < src_line.len) : (end += 1) {
            if (src_line[end] == '\\') {
                end += 1;
                continue;
            }
            if (src_line[end] == ch) return @min(end + 1, src_line.len) - start;
        }
        return src_line.len - start;
    }
    if (!isWordByte(ch)) return 1;
    var end = start;
    while (end < src_line.len and isWordByte(src_line[end])) : (end += 1) {}
    return end - start;
}

/// Terminal cells used by `bytes`: one per codepoint, tabs advancing to the
/// next 8-column stop (as terminals render them).
fn displayWidth(bytes: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '\t') {
            width = (width / 8 + 1) * 8;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        i += @min(len, bytes.len - i);
        width += 1;
    }
    return width;
}
