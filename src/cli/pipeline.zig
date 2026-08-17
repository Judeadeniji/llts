const std = @import("std");
const llts = @import("llts");
const io = llts.io;
const common = @import("common.zig");

pub fn runBytecode(allocator: std.mem.Allocator, path: []const u8, script_args: []const []const u8, max_memory: usize) !void {
    llts.diag.reset();
    llts.runBytecodeFile(allocator, path, script_args, max_memory) catch |err| {
        if (!llts.diag.wasEmitted()) {
            switch (err) {
                error.FileNotFound => io.printStderr("Bytecode file not found: {s}\n", .{path}),
                error.AccessDenied => io.printStderr("Permission denied reading bytecode: {s}\n", .{path}),
                error.TruncatedInput => io.printStderr("Bytecode file is truncated or corrupt: {s}\n", .{path}),
                error.InvalidMagic => io.printStderr("Not a valid LLTS bytecode file: {s}\n", .{path}),
                error.UnsupportedVersion => io.printStderr("Unsupported bytecode version: {s}\n", .{path}),
                else => io.printStderr("Failed to run bytecode {s}: {}\n", .{ path, err }),
            }
        }
        std.process.exit(1);
    };
}

pub fn compileToFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    out_path: []const u8,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    var chunk = llts.compileSource(allocator, path, source, .{ .debug = !release }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
    defer chunk.deinit();

    llts.writeBytecodeFile(allocator, &chunk, out_path) catch |err| {
        common.failExit("Failed to write {s}: {}\n", .{ out_path, err });
    };
}

pub fn runFile(allocator: std.mem.Allocator, path: []const u8, release: bool, script_args: []const []const u8, max_memory: usize) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    llts.runSource(allocator, path, source, .{ .debug = !release, .script_args = script_args, .max_memory_slots = max_memory }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
}

pub fn dumpFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    output_path: ?[]const u8,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
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
        common.failExit("Failed to dump bytecode: {}\n", .{err});
    };

    if (output_path) |out_path| {
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out.items }) catch |err| {
            common.failExit("Failed to write {s}: {}\n", .{ out_path, err });
        };
    } else {
        io.writeStdout(out.items);
    }
}

pub fn emitLlvm(
    allocator: std.mem.Allocator,
    path: []const u8,
    out_path: []const u8,
    ir_path: []const u8,
    release: bool,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    const out_z = try std.mem.Allocator.dupeZ(allocator, u8, out_path);
    defer allocator.free(out_z);

    const ir_owned: ?[:0]u8 = if (ir_path.len > 0) try allocator.dupeZ(u8, ir_path) else null;
    defer if (ir_owned) |p| allocator.free(p);

    llts.pipeline.emitLlvmBitcode(allocator, path, source, out_z, .{
        .debug = !release,
        .ir_path = if (ir_owned) |p| p.ptr else null,
        .verify = true,
    }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            io.printStderr("Error: {}\n", .{err});
        }
        std.process.exit(1);
    };
}
