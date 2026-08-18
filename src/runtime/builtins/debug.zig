//! LLTS native debug/log functions — mirrors `src/vm/builtins/log.zig` and
//! `src/vm/builtins/print_ln.zig`.
//!
//! `__hostLog(level, msg)` writes a leveled log line to stderr.
//! `__printLn(msg, ...args)` does printf-style interpolation and writes
//! to stdout.
//!
//! All I/O is self-contained (no imports from src/io/) because the natives
//! module is compiled as an independent object file.

const std = @import("std");
const util = @import("util.zig");

const dupBytes = util.dupBytes;
const cstr = util.cstr;

// ─────────────────────────── stdio helpers (self-contained) ────────────────

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch return;
        if (n == 0) return;
        remaining = remaining[n..];
    }
}

fn writeStderr(bytes: []const u8) void {
    writeAll(std.posix.STDERR_FILENO, bytes);
}

fn writeStdout(bytes: []const u8) void {
    writeAll(std.posix.STDOUT_FILENO, bytes);
}

// ─────────────────────────── color (self-contained) ───────────────────────

const ansi_reset = "\x1b[0m";
const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";
const ansi_bright_red = "\x1b[91m";
const ansi_bright_yellow = "\x1b[93m";

var color_initialized = false;
var color_enabled = false;

fn colorEnabled() bool {
    if (!color_initialized) {
        color_initialized = true;
        // FORCE_COLOR wins
        if (std.posix.getenv("FORCE_COLOR")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                color_enabled = true;
            }
        }
        if (!color_enabled) {
            if (std.posix.getenv("NO_COLOR")) |v| {
                if (v.len > 0) {
                    color_enabled = false;
                    return color_enabled;
                }
            }
            color_enabled = std.posix.isatty(std.posix.STDERR_FILENO);
        }
    }
    return color_enabled;
}

fn paint(code: []const u8) []const u8 {
    return if (colorEnabled()) code else "";
}

fn resetColor() []const u8 {
    return paint(ansi_reset);
}

// ─────────────────────────── log level ────────────────────────────────────

const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    fn name(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    fn ansi(self: Level) []const u8 {
        return switch (self) {
            .trace => ansi_dim,
            .debug => "\x1b[36m", // cyan
            .info => ansi_green,
            .warn => ansi_bold ++ ansi_bright_yellow,
            .err => ansi_bold ++ ansi_bright_red,
        };
    }

    fn parse(s: []const u8) ?Level {
        if (std.ascii.eqlIgnoreCase(s, "trace")) return .trace;
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        return null;
    }
};

var min_level: Level = .info;
var level_initialized = false;

fn initLevel() void {
    if (level_initialized) return;
    level_initialized = true;
    if (std.posix.getenv("LLTS_LOG_LEVEL")) |v| {
        if (Level.parse(v)) |l| min_level = l;
    }
}

fn levelEnabled(level: Level) bool {
    initLevel();
    return @intFromEnum(level) >= @intFromEnum(min_level);
}

// ─────────────────────────── error value detection ────────────────────────

fn isErrorValue(v: i64) bool {
    return util.__err_is(v);
}

fn formatErrorArg(v: i64, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
    const code_ptr = util.__err_code(v);
    const payload_ptr = util.__err_payload(v);
    const code = cstr(code_ptr);
    const payload = cstr(payload_ptr);
    if (payload.len > 0) {
        buf.writer(alloc).print("{s} — {s}", .{ code, payload }) catch {};
    } else {
        buf.writer(alloc).print("{s}", .{code}) catch {};
    }
}

// ─────────────────────────── __hostLog ────────────────────────────────────

export fn __hostLog(level_ptr: [*:0]const u8, msg_val: i64) i64 {
    const level_str = cstr(level_ptr);
    const level = Level.parse(level_str) orelse .info;
    if (!levelEnabled(level)) return 0;

    const alloc = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    if (isErrorValue(msg_val)) {
        formatErrorArg(msg_val, &buf, alloc);
    } else if (msg_val == 0) {
        buf.appendSlice(alloc, "null") catch {};
    } else {
        const ptr: u64 = @bitCast(@as(u64, @intCast(msg_val)));
        if (ptr >= 4096) {
            const s: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(msg_val)));
            buf.appendSlice(alloc, cstr(s)) catch {};
        } else {
            buf.writer(alloc).print("{d}", .{msg_val}) catch {};
        }
    }

    // Write: "LEVEL: msg\n" with ANSI color
    const c_lvl = paint(level.ansi());
    const r = resetColor();
    var out_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&out_buf, "{s}{s}{s}: {s}\n", .{ c_lvl, level.name(), r, buf.items })) |formatted| {
        writeStderr(formatted);
    } else |_| {
        writeStderr(level.name());
        writeStderr(": ");
        writeStderr(buf.items);
        writeStderr("\n");
    }
    return 0;
}

// ─────────────────────────── __printLn ────────────────────────────────────

fn writeArg(val: i64, out_buf: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
    if (isErrorValue(val)) {
        formatErrorArg(val, out_buf, alloc);
        return;
    }
    if (val == 0) {
        out_buf.appendSlice(alloc, "null") catch return;
        return;
    }
    const ptr: u64 = @bitCast(@as(u64, @intCast(val)));
    if (ptr >= 4096) {
        const s: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(val)));
        out_buf.appendSlice(alloc, cstr(s)) catch return;
        return;
    }
    out_buf.writer(alloc).print("{d}", .{val}) catch {};
}

fn replaceFirst(haystack: []const u8, needle: []const u8, replacement: []const u8, alloc: std.mem.Allocator) ?[]u8 {
    if (std.mem.indexOf(u8, haystack, needle)) |idx| {
        return std.mem.concat(alloc, u8, &.{ haystack[0..idx], replacement, haystack[idx + needle.len ..] }) catch null;
    }
    return alloc.dupe(u8, haystack) catch null;
}

export fn __printLn(msg_val: i64, a: i64, b: i64, c_arg: i64, d: i64) i64 {
    const alloc = std.heap.page_allocator;

    // Get the format string
    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(alloc);
    writeArg(msg_val, &msg_buf, alloc);

    var msg = msg_buf.toOwnedSlice(alloc) catch return 0;
    defer alloc.free(msg);

    const args = [_]i64{ a, b, c_arg, d };
    for (args) |arg| {
        // Stop if no more placeholders
        if (std.mem.indexOf(u8, msg, "{s}") == null and
            std.mem.indexOf(u8, msg, "{i}") == null and
            std.mem.indexOf(u8, msg, "{c}") == null)
            break;

        const idx_s = std.mem.indexOf(u8, msg, "{s}");
        const idx_i = std.mem.indexOf(u8, msg, "{i}");
        const idx_c = std.mem.indexOf(u8, msg, "{c}");

        var min_idx: ?usize = null;
        var placeholder: enum { s, i, c } = .s;

        if (idx_s) |pos| {
            min_idx = pos;
            placeholder = .s;
        }
        if (idx_i) |pos| {
            if (min_idx == null or pos < min_idx.?) {
                min_idx = pos;
                placeholder = .i;
            }
        }
        if (idx_c) |pos| {
            if (min_idx == null or pos < min_idx.?) {
                min_idx = pos;
                placeholder = .c;
            }
        }

        if (min_idx == null) break;

        switch (placeholder) {
            .s => {
                var val_buf: std.ArrayList(u8) = .empty;
                defer val_buf.deinit(alloc);
                writeArg(arg, &val_buf, alloc);
                if (replaceFirst(msg, "{s}", val_buf.items, alloc)) |new_msg| {
                    alloc.free(msg);
                    msg = new_msg;
                } else break;
            },
            .i => {
                var ibuf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&ibuf, "{d}", .{arg}) catch "?";
                if (replaceFirst(msg, "{i}", s, alloc)) |new_msg| {
                    alloc.free(msg);
                    msg = new_msg;
                } else break;
            },
            .c => {
                var cbuf: [1]u8 = undefined;
                cbuf[0] = @intCast(arg);
                if (replaceFirst(msg, "{c}", &cbuf, alloc)) |new_msg| {
                    alloc.free(msg);
                    msg = new_msg;
                } else break;
            },
        }
    }

    // Write to stdout with newline
    var final_buf: std.ArrayList(u8) = .empty;
    defer final_buf.deinit(alloc);
    final_buf.appendSlice(alloc, msg) catch return 0;
    final_buf.append(alloc, '\n') catch return 0;
    writeStdout(final_buf.items);
    return 0;
}
