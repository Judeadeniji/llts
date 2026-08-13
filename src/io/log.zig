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

pub fn log(level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    _ = scope;
    if (!enabled(level)) return;
    const c_lvl = color.paint(level.ansi());
    const r = color.r();
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |body| {
        out.printStderr("{s}{s}{s}: {s}\n", .{ c_lvl, level.name(), r, body });
    } else |_| {
        const owned = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch {
            out.printStderr("{s}{s}{s}: (log format failed)\n", .{ c_lvl, level.name(), r });
            return;
        };
        defer std.heap.page_allocator.free(owned);
        out.printStderr("{s}{s}{s}: {s}\n", .{ c_lvl, level.name(), r, owned });
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
