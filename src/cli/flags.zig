const std = @import("std");
const zli = @import("zli");

pub const log_level = zli.Flag{
    .name = "log-level",
    .description = "Set log level (err, warn, info, debug)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const release = zli.Flag{
    .name = "release",
    .shortcut = "r",
    .description = "Disable debug info",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const max_memory = zli.Flag{
    .name = "max-memory",
    .shortcut = "m",
    .description = "Max memory slots (default 1048576, env LLTS_MAX_MEMORY)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const version_flag = zli.Flag{
    .name = "version",
    .shortcut = "V",
    .description = "Show version information and exit",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn addCompileFlags(cmd: *zli.Command) !void {
    try cmd.addFlag(log_level);
    try cmd.addFlag(release);
}

pub fn addRunFlags(cmd: *zli.Command) !void {
    try addCompileFlags(cmd);
    try cmd.addFlag(max_memory);
}
