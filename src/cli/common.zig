const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const io = llts.io;

pub fn setLogLevel(ctx: zli.CommandContext) void {
    const str = ctx.flag("log-level", []const u8);
    if (str.len > 0) {
        if (io.Level.parse(str)) |l| {
            io.log.setLevel(l);
        } else {
            failExit("Invalid log level: {s}\n", .{str});
        }
    }
}

pub fn getMaxMemory(allocator: std.mem.Allocator, ctx: zli.CommandContext) usize {
    if (std.process.getEnvVarOwned(allocator, "LLTS_MAX_MEMORY")) |env_val| {
        defer allocator.free(env_val);
        if (std.fmt.parseInt(usize, env_val, 10)) |v| return v else |_| {}
    } else |_| {}
    const flag_val = ctx.flag("max-memory", []const u8);
    if (flag_val.len > 0) {
        if (std.fmt.parseInt(usize, flag_val, 10)) |v| return v else |_| {}
    }
    return 1048576;
}

pub fn getComptimeMaxLoopIterations(allocator: std.mem.Allocator, ctx: zli.CommandContext) ?usize {
    const flag_val = ctx.flag("comptime-max-loop-iterations", []const u8);
    if (flag_val.len > 0) {
        if (std.fmt.parseInt(usize, flag_val, 10)) |v| return v else |_| {}
    }
    if (std.process.getEnvVarOwned(allocator, "LLTS_COMPTIME_MAX_LOOP_ITERATIONS")) |env_val| {
        defer allocator.free(env_val);
        if (std.fmt.parseInt(usize, env_val, 10)) |v| return v else |_| {}
    } else |_| {}
    return null;
}

pub fn getZigBin(allocator: std.mem.Allocator, ctx: zli.CommandContext) []const u8 {
    const flag_val = ctx.flag("zig-bin", []const u8);
    if (flag_val.len > 0) return flag_val;
    if (std.process.getEnvVarOwned(allocator, "LLTS_ZIG_BIN")) |env_val| {
        return env_val;
    } else |_| {}
    return "zig";
}

pub fn getOptimize(ctx: zli.CommandContext) ?[]const u8 {
    const opt_val = ctx.flag("optimize", []const u8);
    if (opt_val.len > 0) return opt_val;
    if (ctx.flag("release", bool)) return "ReleaseFast";
    return null;
}

pub fn getTarget(ctx: zli.CommandContext) ?[]const u8 {
    const flag_val = ctx.flag("target", []const u8);
    if (flag_val.len > 0) return flag_val;
    return null;
}

pub fn getRuntimePath(ctx: zli.CommandContext) ?[]const u8 {
    const flag_val = ctx.flag("runtime-path", []const u8);
    if (flag_val.len > 0) return flag_val;
    return null;
}

fn appendSplitTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) : (i += 1) {}
        if (i >= text.len) break;

        var token: std.ArrayList(u8) = .empty;
        defer token.deinit(allocator);
        var in_quote: ?u8 = null;
        while (i < text.len) {
            const c = text[i];
            if (in_quote) |q| {
                if (c == q) {
                    in_quote = null;
                } else if (c == '\\' and i + 1 < text.len) {
                    i += 1;
                    try token.append(allocator, text[i]);
                } else {
                    try token.append(allocator, c);
                }
            } else {
                if (c == '"' or c == '\'') {
                    in_quote = c;
                } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                    break;
                } else if (c == '\\' and i + 1 < text.len) {
                    i += 1;
                    try token.append(allocator, text[i]);
                } else {
                    try token.append(allocator, c);
                }
            }
            i += 1;
        }
        try list.append(allocator, try token.toOwnedSlice(allocator));
    }
}

pub fn getZigArgs(allocator: std.mem.Allocator, ctx: zli.CommandContext) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    if (std.process.getEnvVarOwned(allocator, "LLTS_ZIG_ARGS")) |env_val| {
        defer allocator.free(env_val);
        try appendSplitTokens(allocator, &args, env_val);
    } else |_| {}

    const flag_val = ctx.flag("zig-args", []const u8);
    if (flag_val.len > 0) {
        try appendSplitTokens(allocator, &args, flag_val);
    }

    if (ctx.positional_args.len > 1) {
        for (ctx.positional_args[1..]) |arg| {
            try args.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    return try args.toOwnedSlice(allocator);
}

pub fn failExit(comptime format: []const u8, args: anytype) noreturn {
    io.printStderr(format, args);
    std.process.exit(1);
}

pub fn readSourceOrExit(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        failExit("Failed to read {s}: {}\n", .{ path, err });
    };
}
