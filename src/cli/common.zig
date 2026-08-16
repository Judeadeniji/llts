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

pub fn failExit(comptime format: []const u8, args: anytype) noreturn {
    io.printStderr(format, args);
    std.process.exit(1);
}

pub fn readSourceOrExit(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        failExit("Failed to read {s}: {}\n", .{ path, err });
    };
}
