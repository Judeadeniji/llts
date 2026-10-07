const std = @import("std");
const scanner = @import("scanner/root.zig");
const parser = @import("parser/root.zig");
const compiler = @import("compiler/root.zig");
const chunk_mod = @import("bytecode/chunk.zig");
const serialize = @import("bytecode/serialize.zig");
const vm_state = @import("vm/state.zig");
const execute = @import("vm/execute/root.zig");
const builtins = @import("vm/builtins/root.zig");
const llvm_backend = @import("compiler/llvm/root.zig");
const print_fmt = @import("vm/builtins/print.zig");
const report = @import("errors/report.zig");

pub const RunOptions = struct {
    debug: bool = true,
    strict: bool = false,
    comptime_max_loop_iterations: ?usize = null,
    /// Extra argv forwarded to `os.args()` as argv[1..] (argv[0] is the script path).
    script_args: []const []const u8 = &.{},
    max_memory_slots: usize = 1048576,
};

pub const EmitLlvmOptions = struct {
    debug: bool = true,
    strict: bool = false,
    comptime_max_loop_iterations: ?usize = null,
    /// When set, also write textual LLVM IR to this path.
    ir_path: ?[*:0]const u8 = null,
    /// Run LLVM module verification (default true).
    verify: bool = true,
};

pub fn compileSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !chunk_mod.Chunk {
    var scan_result = try scanner.scan(allocator, source, path);
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source, null);
    defer doc.deinit();

    return try compiler.compile(allocator, &doc, .{
        .debug = options.debug,
        .strict = options.strict,
        .comptime_max_loop_iterations = options.comptime_max_loop_iterations,
    });
}

pub fn runChunk(
    allocator: std.mem.Allocator,
    chunk: *chunk_mod.Chunk,
    script_path: []const u8,
    script_args: []const []const u8,
    max_memory_slots: usize,
) !void {
    var state = try vm_state.VMState.init(allocator, chunk, max_memory_slots);
    defer state.deinit();
    state.script_path = script_path;
    state.script_args = script_args;
    try builtins.registerBuiltins(&state, chunk);
    execute.execute(&state, 0) catch |err| {
        if (err == error.TypeError) {
            const f = if (state.frame_count > 0) state.frame() else null;
            if (f) |frame| {
                std.debug.print("runtime TypeError in {s} ({s}:{d}:{d})\n", .{
                    frame.func_name,
                    if (frame.file.len > 0) frame.file else script_path,
                    frame.line,
                    frame.column,
                });
            } else {
                std.debug.print("runtime TypeError before first frame\n", .{});
            }
        }
        return err;
    };

    if (state.sp > 0 and state.isErrorValue(state.stack_buf[0])) {
        const err_val = state.stack_buf[0];
        const p: i32 = switch (err_val) {
            .ptr => |x| x,
            .i64 => |x| @intCast(x),
            else => unreachable,
        };
        var msg_buf: std.ArrayList(u8) = .empty;
        defer msg_buf.deinit(state.allocator);
        try print_fmt.writeValue(&state, &msg_buf, state.slot(p).*);
        const payload = state.slot(p + 1).*;
        if (payload != .null) {
            try msg_buf.appendSlice(state.allocator, " — ");
            try print_fmt.writeValue(&state, &msg_buf, payload);
        }

        const file = if (state.current_source_index < state.chunk.sources.items.len)
            state.chunk.sources.items[state.current_source_index].path
        else if (state.chunk.file.len > 0)
            state.chunk.file
        else
            script_path;
        const source = state.sourceForFile(file);
        if (state.current_line > 0 and source.len > 0) {
            report.reportSourceErrorWithFrame(file, source, state.current_line, state.current_column, msg_buf.items, "main");
        } else {
            report.reportRuntimeError(msg_buf.items);
            report.reportLocationFrameCol(file, 1, 1, "main");
        }
        return error.RuntimeError;
    }
}

pub fn runSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !void {
    var chunk = try compileSource(allocator, path, source, options);
    defer chunk.deinit();
    try runChunk(allocator, &chunk, path, options.script_args, options.max_memory_slots);
}

pub fn writeBytecodeFile(allocator: std.mem.Allocator, chunk: *const chunk_mod.Chunk, path: []const u8) !void {
    try serialize.writeFile(allocator, chunk, path);
}

pub fn readBytecodeFile(allocator: std.mem.Allocator, path: []const u8) !chunk_mod.Chunk {
    return try serialize.readFile(allocator, path);
}

pub fn runBytecodeFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    script_args: []const []const u8,
    max_memory_slots: usize,
) !void {
    var chunk = try readBytecodeFile(allocator, path);
    defer chunk.deinit();
    try runChunk(allocator, &chunk, path, script_args, max_memory_slots);
}

/// Lower a source file to LLVM IR and write bitcode (and optional textual IR).
pub fn emitLlvmBitcode(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    out_path: ?[*:0]const u8,
    options: EmitLlvmOptions,
) !void {
    var scan_result = try scanner.scan(allocator, source, path);
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source, null);
    defer doc.deinit();

    var state = try compiler.analyze(allocator, &doc, .{
        .debug = options.debug,
        .strict = options.strict,
        .comptime_max_loop_iterations = options.comptime_max_loop_iterations,
    });
    defer {
        state.chunk.deinit();
        compiler.state_mod.deinit(&state);
    }

    var lc = llvm_backend.LlvmContext.init(allocator, path, &state);
    defer lc.deinit();

    try llvm_backend.codegen(&lc, &doc);

    if (options.verify) try lc.verify();

    if (options.ir_path) |irp| try lc.writeIr(irp);

    if (out_path) |p| try lc.writeBitcode(p);
}
