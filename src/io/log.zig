const std = @import("std");
const out = @import("out.zig");
const color = @import("color.zig");

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn ansi(self: Level) []const u8 {
        return switch (self) {
            .trace => color.dim,
            .debug => color.cyan,
            .info => color.green,
            .warn => color.bold ++ color.bright_yellow,
            .err => color.bold ++ color.bright_red,
        };
    }

    pub fn parse(s: []const u8) ?Level {
        if (std.ascii.eqlIgnoreCase(s, "trace")) return .trace;
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        return null;
    }
};

var min_level: Level = .info;

pub fn setLevel(level: Level) void {
    min_level = level;
}

pub fn getLevel() Level {
    return min_level;
}

/// Read `LLTS_LOG_LEVEL` from the environment (no-op if unset/invalid).
pub fn initFromEnv() void {
    const val = std.posix.getenv("LLTS_LOG_LEVEL") orelse return;
    if (Level.parse(val)) |l| setLevel(l);
}

pub fn enabled(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(min_level);
}

/// Scopes that say nothing — the empty scope and Zig's `.default` — are omitted
/// so ordinary lines stay `INFO: msg`.
pub fn displayScope(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "default")) return "";
    return scope;
}

/// Render one complete log line: `LEVEL: body\n`, or `LEVEL [scope]: body\n`
/// when the scope has something to say. Pure — safe to unit test.
pub fn formatLine(buf: []u8, level: Level, scope: []const u8, body: []const u8) error{NoSpaceLeft}![]const u8 {
    const c_lvl = color.paint(level.ansi());
    const r = color.r();
    const sc = displayScope(scope);
    if (sc.len == 0) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}: {s}\n", .{ c_lvl, level.name(), r, body });
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s} {s}[{s}]{s}: {s}\n", .{ c_lvl, level.name(), r, color.paint(color.dim), sc, r, body });
}

fn writeLine(level: Level, scope: []const u8, body: []const u8) void {
    var buf: [4352]u8 = undefined;
    if (formatLine(&buf, level, scope, body)) |line| {
        out.writeStderr(line);
        return;
    } else |_| {}
    // Body longer than the scratch buffer — same line, heap-allocated.
    const c_lvl = color.paint(level.ansi());
    const r = color.r();
    const sc = displayScope(scope);
    const owned = if (sc.len == 0)
        std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}{s}: {s}\n", .{ c_lvl, level.name(), r, body })
    else
        std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}{s} {s}[{s}]{s}: {s}\n", .{ c_lvl, level.name(), r, color.paint(color.dim), sc, r, body });
    const rendered = owned catch {
        out.writeStderr("(log format failed)\n");
        return;
    };
    defer std.heap.page_allocator.free(rendered);
    out.writeStderr(rendered);
}

pub fn log(level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |body| {
        writeLine(level, scope, body);
    } else |_| {
        const owned = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch {
            writeLine(level, scope, "(log format failed)");
            return;
        };
        defer std.heap.page_allocator.free(owned);
        writeLine(level, scope, owned);
    }
}

pub fn trace(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.trace, scope, fmt, args);
}
pub fn debug(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.debug, scope, fmt, args);
}
pub fn info(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.info, scope, fmt, args);
}
pub fn warn(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.warn, scope, fmt, args);
}
pub fn err(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.err, scope, fmt, args);
}

test "formatLine: no scope keeps the plain `LEVEL: body` shape" {
    color.setEnabled(false);
    var buf: [256]u8 = undefined;
    const line = try formatLine(&buf, .warn, "", "disk almost full");
    try std.testing.expectEqualStrings("WARN: disk almost full\n", line);
}

test "formatLine: a scope renders as LEVEL [scope]: body" {
    color.setEnabled(false);
    var buf: [256]u8 = undefined;
    const line = try formatLine(&buf, .err, "vm", "stack overflow");
    try std.testing.expectEqualStrings("ERROR [vm]: stack overflow\n", line);
}

test "displayScope drops the empty and default scopes" {
    try std.testing.expectEqualStrings("", displayScope(""));
    try std.testing.expectEqualStrings("", displayScope("default"));
    try std.testing.expectEqualStrings("compiler", displayScope("compiler"));
}
