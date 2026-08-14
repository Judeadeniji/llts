const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const io = llts.io;

pub const std_options: std.Options = .{
    .logFn = zigLogFn,
};

fn zigLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level: io.Level = switch (message_level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const scope_name = @tagName(scope);
    io.log.log(level, scope_name, format, args);
}

const log_level_flag = zli.Flag{
    .name = "log-level",
    .description = "Set log level (err, warn, info, debug)",
    .type = .String,
    .default_value = .{ .String = "" },
};

const release_flag = zli.Flag{
    .name = "release",
    .shortcut = "r",
    .description = "Disable debug info",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn main() !void {
    io.color.initFromEnv();
    io.log.initFromEnv();

    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var wbuf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&rbuf);
    const stdin = &stdin_reader.interface;

    const root = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "llts",
        .description = "LLTS — a general-purpose language",
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    }, showHelp);
    defer root.deinit();

    try root.addFlag(log_level_flag);
    try root.addFlag(release_flag);

    const run_cmd = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "run",
        .description = "Run an LLTS source or bytecode file",
    }, runFileCmd);
    try run_cmd.addFlag(log_level_flag);
    try run_cmd.addFlag(release_flag);
    try run_cmd.addPositionalArg(.{
        .name = "file",
        .description = "Source (.lls) or bytecode (.llb) file to run",
        .required = true,
    });
    try run_cmd.addPositionalArg(.{
        .name = "args",
        .description = "Arguments forwarded to the program",
        .required = false,
        .variadic = true,
    });
    try root.addCommand(run_cmd);

    const build_cmd = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "build",
        .description = "Compile an LLTS source file to bytecode",
    }, buildCmd);
    try build_cmd.addFlag(log_level_flag);
    try build_cmd.addFlag(release_flag);
    try build_cmd.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output bytecode file path",
        .type = .String,
        .default_value = .{ .String = "out.llb" },
    });
    try build_cmd.addPositionalArg(.{
        .name = "file",
        .description = "Source file to compile",
        .required = true,
    });
    try root.addCommand(build_cmd);

    const dump_cmd = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "dump",
        .description = "Dump bytecode from an LLTS source file",
    }, dumpCmd);
    try dump_cmd.addFlag(log_level_flag);
    try dump_cmd.addFlag(release_flag);
    try dump_cmd.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output file path",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try dump_cmd.addPositionalArg(.{
        .name = "file",
        .description = "Source file to compile and dump",
        .required = true,
    });
    try root.addCommand(dump_cmd);

    const smoke_cmd = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "smoke",
        .description = "Run the smoke test",
    }, smokeCmd);
    try root.addCommand(smoke_cmd);

    try root.execute(.{});
}

fn showHelp(ctx: zli.CommandContext) !void {
    setLogLevel(ctx);
    try ctx.command.printHelp();
}

fn setLogLevel(ctx: zli.CommandContext) void {
    const str = ctx.flag("log-level", []const u8);
    if (str.len > 0) {
        if (io.Level.parse(str)) |l| {
            io.log.setLevel(l);
        } else {
            io.printStderr("Invalid log level: {s}\n", .{str});
            std.process.exit(1);
        }
    }
}

fn runFileCmd(ctx: zli.CommandContext) !void {
    setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const file = ctx.getArg("file").?;

    var program_args: []const []const u8 = &[_][]const u8{};
    if (ctx.positional_args.len > 1) {
        program_args = ctx.positional_args[1..];
    }

    if (llts.serialize.isBytecodePath(file)) {
        try runBytecode(ctx.allocator, file, program_args);
    } else {
        try runFile(ctx.allocator, file, release, program_args);
    }
}

fn buildCmd(ctx: zli.CommandContext) !void {
    setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const file = ctx.getArg("file").?;
    const out_path = ctx.flag("output", []const u8);

    if (llts.serialize.isBytecodePath(file)) {
        io.printStderr("Cannot compile a .llb file; use a .lls source\n", .{});
        std.process.exit(1);
    }

    try compileFile(ctx.allocator, file, release, out_path);
}

fn dumpCmd(ctx: zli.CommandContext) !void {
    setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const file = ctx.getArg("file").?;
    const out_val = ctx.flag("output", []const u8);
    const out_path: ?[]const u8 = if (out_val.len > 0) out_val else null;

    if (llts.serialize.isBytecodePath(file)) {
        io.printStderr("Cannot dump bytecode from a .llb file; use a .lls source\n", .{});
        std.process.exit(1);
    }

    try dumpFile(ctx.allocator, file, release, out_path);
}

fn smokeCmd(ctx: zli.CommandContext) !void {
    var c = llts.Chunk.init(ctx.allocator);
    defer c.deinit();

    const idx = try c.addConstant(.{ .int = 42 });
    try c.writeOp(.OP_CONSTANT);
    try c.write(@intCast((idx >> 8) & 0xff));
    try c.write(@intCast(idx & 0xff));
    try c.writeOp(.OP_PRINT);
    try c.write(1);

    try llts.runChunk(ctx.allocator, &c);
}

fn runBytecode(allocator: std.mem.Allocator, path: []const u8, script_args: []const []const u8) !void {
    llts.diag.reset();
    llts.runBytecodeFile(allocator, path, script_args) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Failed to run bytecode {s}: {}\n", .{ path, err });
        }
        std.process.exit(1);
    };
}

fn compileFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    out_path: []const u8,
) !void {
    llts.diag.reset();

    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        io.printStderr("Failed to read {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var chunk = llts.compileSource(allocator, path, source, .{ .debug = !release }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
    defer chunk.deinit();

    llts.writeBytecodeFile(allocator, &chunk, out_path) catch |err| {
        io.printStderr("Failed to write {s}: {}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

fn runFile(allocator: std.mem.Allocator, path: []const u8, release: bool, script_args: []const []const u8) !void {
    llts.diag.reset();

    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        io.printStderr("Failed to read {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    llts.runSource(allocator, path, source, .{ .debug = !release, .script_args = script_args }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
}

fn dumpFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    output_path: ?[]const u8,
) !void {
    llts.diag.reset();

    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        io.printStderr("Failed to read {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var chunk = llts.compileSource(allocator, path, source, .{ .debug = !release }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
    defer chunk.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    llts.disasm.dump(&chunk, out.writer(allocator)) catch |err| {
        io.printStderr("Failed to dump bytecode: {}\n", .{err});
        std.process.exit(1);
    };

    if (output_path) |out_path| {
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out.items }) catch |err| {
            io.printStderr("Failed to write {s}: {}\n", .{ out_path, err });
            std.process.exit(1);
        };
    } else {
        io.writeStdout(out.items);
    }
}
