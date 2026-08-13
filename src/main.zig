const std = @import("std");
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

pub fn main() !void {
    io.color.initFromEnv();
    io.log.initFromEnv();

    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // argv0

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    while (args.next()) |a| try arg_list.append(gpa, a);

    var input_path: ?[]const u8 = null;
    var release = false;
    var dump_bytecode = false;
    var dump_output: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < arg_list.items.len) {
        const arg = arg_list.items[i];
        i += 1;
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            if (i >= arg_list.items.len) {
                io.printStderr("Missing value for input\n", .{});
                std.process.exit(1);
            }
            input_path = arg_list.items[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i >= arg_list.items.len) {
                io.printStderr("Missing value for output\n", .{});
                std.process.exit(1);
            }
            output_path = arg_list.items[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dump-bytecode")) {
            dump_bytecode = true;
            if (i < arg_list.items.len and !std.mem.startsWith(u8, arg_list.items[i], "-")) {
                dump_output = arg_list.items[i];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            if (i >= arg_list.items.len) {
                io.printStderr("Missing value for --log-level\n", .{});
                std.process.exit(1);
            }
            const val = arg_list.items[i];
            i += 1;
            if (io.Level.parse(val)) |l| {
                io.log.setLevel(l);
            } else {
                io.printStderr("Invalid log level: {s}\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            try runSmoke(gpa);
            return;
        } else {
            io.printStderr("Invalid argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const path = input_path orelse {
        io.printStderr("Usage: llts -i <file.lls|file.llb> [-r] [-o file.llb] [-d [FILE]] [--log-level LEVEL]\n", .{});
        std.process.exit(1);
    };

    if (dump_bytecode) {
        if (output_path != null) {
            io.printStderr("-d and -o are mutually exclusive\n", .{});
            std.process.exit(1);
        }
        if (llts.serialize.isBytecodePath(path)) {
            io.printStderr("Cannot dump bytecode from a .llb file; use a .lls source\n", .{});
            std.process.exit(1);
        }
        try dumpFile(gpa, path, release, dump_output);
        return;
    }

    if (output_path != null) {
        if (llts.serialize.isBytecodePath(path)) {
            io.printStderr("Cannot compile a .llb file; use a .lls source with -o\n", .{});
            std.process.exit(1);
        }
        try compileFile(gpa, path, release, output_path.?);
        return;
    }

    if (llts.serialize.isBytecodePath(path)) {
        try runBytecode(gpa, path);
        return;
    }

    try runFile(gpa, path, release);
}

fn runSmoke(allocator: std.mem.Allocator) !void {
    var c = llts.Chunk.init(allocator);
    defer c.deinit();

    // print(42)
    const idx = try c.addConstant(.{ .int = 42 });
    try c.writeOp(.OP_CONSTANT);
    try c.write(@intCast((idx >> 8) & 0xff));
    try c.write(@intCast(idx & 0xff));
    try c.writeOp(.OP_PRINT);
    try c.write(1);

    try llts.runChunk(allocator, &c);
}

fn runBytecode(allocator: std.mem.Allocator, path: []const u8) !void {
    llts.diag.reset();
    llts.runBytecodeFile(allocator, path) catch |err| {
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

fn runFile(allocator: std.mem.Allocator, path: []const u8, release: bool) !void {
    llts.diag.reset();

    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        io.printStderr("Failed to read {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    llts.runSource(allocator, path, source, .{ .debug = !release }) catch |err| {
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
