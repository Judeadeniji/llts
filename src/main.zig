const std = @import("std");
const llts = @import("llts");

pub fn main() !void {
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
                std.debug.print("Missing value for input\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            try runSmoke(gpa);
            return;
        } else {
            std.debug.print("Invalid argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const path = input_path orelse {
        std.debug.print("Usage: llts -i <file.lls> [-r]\n", .{});
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
    try c.write(idx);
    try c.writeOp(.OP_PRINT);
    try c.write(1);

    try llts.runChunk(allocator, &c);
}

fn runFile(allocator: std.mem.Allocator, path: []const u8, release: bool) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    llts.runSource(allocator, path, source, .{ .debug = !release }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}
