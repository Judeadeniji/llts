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

pub const optimize = zli.Flag{
    .name = "optimize",
    .shortcut = "O",
    .description = "Optimization mode for native compilation (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const target = zli.Flag{
    .name = "target",
    .description = "Target triple for native compilation (e.g. x86_64-linux, aarch64-macos)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const strict = zli.Flag{
    .name = "strict",
    .shortcut = "s",
    .description = "Enforce sound type system (mandatory parameter types, strict null/union safety)",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const strict_native = zli.Flag{
    .name = "strict",
    .shortcut = "s",
    .description = "Enforce sound type system — enabled by default for native targets",
    .type = .Bool,
    .default_value = .{ .Bool = true },
};

pub const native = zli.Flag{
    .name = "native",
    .shortcut = "n",
    .description = "Compile to a native binary via the native backend (implies --strict)",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const emit_zig = zli.Flag{
    .name = "emit-zig",
    .description = "Emit runtime-driving Zig code (for inspection or compilation)",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const emit_bin = zli.Flag{
    .name = "emit-bin",
    .description = "Emit native machine code binary",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const emit_bytecode = zli.Flag{
    .name = "emit-bytecode",
    .description = "Emit LLTS bytecode (.llb)",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const emit_asm = zli.Flag{
    .name = "emit-asm",
    .description = "Emit target assembly (.s)",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub const zig_args = zli.Flag{
    .name = "zig-args",
    .description = "Options forwarded to the zig cli (e.g. --zig-args=\"-fstrip -flto\", env LLTS_ZIG_ARGS)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const zig_bin = zli.Flag{
    .name = "zig-bin",
    .description = "Path to the zig compiler executable (default 'zig', env LLTS_ZIG_BIN)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const runtime_path = zli.Flag{
    .name = "runtime-path",
    .description = "Path to the LLTS runtime module for the emitted code (default 'src/runtime/root.zig')",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const max_memory = zli.Flag{
    .name = "max-memory",
    .shortcut = "m",
    .description = "Max memory slots (default 1048576, env LLTS_MAX_MEMORY)",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub const comptime_max_loop_iterations = zli.Flag{
    .name = "comptime-max-loop-iterations",
    .description = "Max loop iterations in constant evaluation (default 100000, env LLTS_COMPTIME_MAX_LOOP_ITERATIONS)",
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
    try cmd.addFlag(optimize);
    try cmd.addFlag(target);
    try cmd.addFlag(strict);
    try cmd.addFlag(native);
    try cmd.addFlag(emit_zig);
    try cmd.addFlag(emit_bin);
    try cmd.addFlag(emit_bytecode);
    try cmd.addFlag(emit_asm);
    try cmd.addFlag(zig_args);
    try cmd.addFlag(zig_bin);
    try cmd.addFlag(runtime_path);
    try cmd.addFlag(comptime_max_loop_iterations);
}

pub fn addRunFlags(cmd: *zli.Command) !void {
    try addCompileFlags(cmd);
    try cmd.addFlag(max_memory);
}

pub fn addEmitZigFlags(cmd: *zli.Command) !void {
    try cmd.addFlag(log_level);
    try cmd.addFlag(release);
    try cmd.addFlag(strict_native);
    try cmd.addFlag(runtime_path);
    try cmd.addFlag(comptime_max_loop_iterations);
}
