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

    var input_path: ?[]const u8 = null;
    var release = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_path = args.next() orelse {
                io.printStderr("Missing value for input\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            const val = args.next() orelse {
                io.printStderr("Missing value for --log-level\n", .{});
                std.process.exit(1);
            };
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
        io.printStderr("Usage: llts -i <file.lls> [-r] [--log-level LEVEL]\n", .{});
        std.process.exit(1);
    };

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
