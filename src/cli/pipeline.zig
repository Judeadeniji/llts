const std = @import("std");
const llts = @import("llts");
const io = llts.io;
const common = @import("common.zig");

pub fn runBytecode(allocator: std.mem.Allocator, path: []const u8, script_args: []const []const u8, max_memory: usize) !void {
    llts.diag.reset();
    llts.runBytecodeFile(allocator, path, script_args, max_memory) catch |err| {
        if (!llts.diag.wasEmitted()) {
            switch (err) {
                error.FileNotFound => common.failExit("Cannot read bytecode file \"{s}\": file not found", .{path}),
                error.AccessDenied => common.failExit("Cannot read bytecode file \"{s}\": permission denied", .{path}),
                error.TruncatedInput => common.failExit("Bytecode file \"{s}\" is truncated or corrupt; rebuild it with `llts build`", .{path}),
                error.InvalidMagic => common.failExit("\"{s}\" is not a valid LLTS bytecode file", .{path}),
                error.UnsupportedVersion => common.failExit("Unsupported bytecode version in \"{s}\"; rebuild it with `llts build`", .{path}),
                else => common.failExit("Cannot run bytecode \"{s}\": {s}", .{ path, common.reason(err) }),
            }
        }
        std.process.exit(1);
    };
}

pub fn compileToFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    strict: bool,
    out_path: []const u8,
    comptime_max_loop_iterations: ?usize,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    var chunk = llts.compileSource(allocator, path, source, .{
        .debug = !release,
        .strict = strict,
        .comptime_max_loop_iterations = comptime_max_loop_iterations,
    }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            common.failExit("Compilation failed: {s}", .{common.reason(err)});
        }
        std.process.exit(1);
    };
    defer chunk.deinit();

    llts.writeBytecodeFile(allocator, &chunk, out_path) catch |err| {
        common.failExit("Cannot write \"{s}\": {s}", .{ out_path, common.reason(err) });
    };
}

pub fn runFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    strict: bool,
    script_args: []const []const u8,
    max_memory: usize,
    comptime_max_loop_iterations: ?usize,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    llts.runSource(allocator, path, source, .{
        .debug = !release,
        .strict = strict,
        .script_args = script_args,
        .max_memory_slots = max_memory,
        .comptime_max_loop_iterations = comptime_max_loop_iterations,
    }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            common.failExit("Run failed: {s}", .{common.reason(err)});
        }
        std.process.exit(1);
    };
}

pub fn dumpFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    strict: bool,
    output_path: ?[]const u8,
    comptime_max_loop_iterations: ?usize,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    var chunk = llts.compileSource(allocator, path, source, .{
        .debug = !release,
        .strict = strict,
        .comptime_max_loop_iterations = comptime_max_loop_iterations,
    }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            common.failExit("Compilation failed: {s}", .{common.reason(err)});
        }
        std.process.exit(1);
    };
    defer chunk.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    llts.disasm.dump(&chunk, out.writer(allocator)) catch |err| {
        common.failExit("Cannot dump bytecode: {s}", .{common.reason(err)});
    };

    if (output_path) |out_path| {
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out.items }) catch |err| {
            common.failExit("Cannot write \"{s}\": {s}", .{ out_path, common.reason(err) });
        };
    } else {
        io.writeStdout(out.items);
    }
}

pub fn emitZig(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    strict: bool,
    output_path: ?[]const u8,
    comptime_max_loop_iterations: ?usize,
    runtime_path: ?[]const u8,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    llts.pipeline.emitZigCode(allocator, path, source, out.writer(allocator), .{
        .debug = !release,
        .strict = strict,
        .comptime_max_loop_iterations = comptime_max_loop_iterations,
        .runtime_path = runtime_path orelse "src/runtime/root.zig",
    }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            common.failExit("Zig emit failed: {s}", .{common.reason(err)});
        }
        std.process.exit(1);
    };

    if (output_path) |out_path| {
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out.items }) catch |err| {
            common.failExit("Cannot write \"{s}\": {s}", .{ out_path, common.reason(err) });
        };
    } else {
        io.writeStdout(out.items);
    }
}

/// Compile an LLTS source file to a native binary via the native backend.
/// Strict mode is on by default for native targets.
pub fn compileNative(
    allocator: std.mem.Allocator,
    path: []const u8,
    release: bool,
    strict: bool,
    out_path: []const u8,
    comptime_max_loop_iterations: ?usize,
    zig_bin: []const u8,
    target: ?[]const u8,
    zig_opt: ?[]const u8,
    emit_mode: llts.pipeline.EmitZigOptions.EmitMode,
    runtime_path: ?[]const u8,
    zig_args: []const []const u8,
) !void {
    llts.diag.reset();
    const source = common.readSourceOrExit(allocator, path);
    defer allocator.free(source);

    llts.pipeline.compileNativeBinary(allocator, path, source, out_path, .{
        .debug = !release,
        .strict = strict,
        .comptime_max_loop_iterations = comptime_max_loop_iterations,
        .zig_bin = zig_bin,
        .target = target,
        .zig_optimize = zig_opt,
        .emit_mode = emit_mode,
        .runtime_path = runtime_path orelse "src/runtime/root.zig",
        .zig_args = zig_args,
    }) catch |err| {
        if (!llts.diag.wasEmitted()) {
            common.failExit("Native compile failed: {s}", .{common.reason(err)});
        }
        std.process.exit(1);
    };
}
