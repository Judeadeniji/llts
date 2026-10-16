const std = @import("std");
const scanner = @import("scanner/root.zig");
const parser = @import("parser/root.zig");
const compiler = @import("compiler/root.zig");
const chunk_mod = @import("bytecode/chunk.zig");
const serialize = @import("bytecode/serialize.zig");
const vm_state = @import("vm/state.zig");
const execute = @import("vm/execute/root.zig");
const builtins = @import("vm/builtins/root.zig");
const zig_backend = @import("compiler/zig/root.zig");
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

pub const EmitZigOptions = struct {
    debug: bool = true,
    /// Native emission typechecks under strict soundness **by default**
    /// (native-backend Core Principle #1: "Strict by Default"). Callers may
    /// pass `false` explicitly to opt out during the transition.
    strict: bool = true,
    comptime_max_loop_iterations: ?usize = null,
    /// @import path for the LLTS runtime, written into the emitted Zig source.
    runtime_path: []const u8 = "src/runtime/root.zig",
    /// Path to zig compiler executable (defaults to "zig", or env LLTS_ZIG_BIN).
    zig_bin: []const u8 = "zig",
    /// Target triple for native compilation (e.g. x86_64-linux, aarch64-macos).
    target: ?[]const u8 = null,
    /// Optimization mode passed to `zig build-exe` (e.g. "ReleaseFast", "ReleaseSmall", "Debug").
    zig_optimize: ?[]const u8 = null,
    /// What output format to emit.
    emit_mode: EmitMode = .bin,
    /// Additional arguments/options forwarded directly to `zig build-exe`.
    zig_args: []const []const u8 = &.{},

    pub const EmitMode = enum {
        bin,
        asm_code,
        zig_source,
    };
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


/// Emit a source file as runtime-driving Zig code (the native backend output).
/// Pass any `std.io` writer; the result is a monolithic `.zig` compilation unit.
pub fn emitZigCode(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    writer: anytype,
    options: EmitZigOptions,
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

    try zig_backend.emitRuntimeZig(allocator, &doc, &state, writer, .{
        .release = !options.debug,
        .runtime_path = options.runtime_path,
    });
}

/// Compile an LLTS source file to a native binary by emitting runtime Zig and
/// invoking `zig build-exe`.
///
/// The full front half (scan → parse → strict typecheck → emit) runs here, so
/// soundness is enforced at the native entry point even before Phase 4 lands.
///
/// Phase 4 implementation pending — returns NotImplemented after emission.
pub fn compileNativeBinary(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    out_binary_path: []const u8,
    options: EmitZigOptions,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try emitZigCode(allocator, path, source, out.writer(allocator), options);

    _ = out_binary_path;
    // TODO Phase 4: write `out.items` to a temp file and spawn
    //   `zig build-exe <tmp> -Mruntime=… -O <zig_optimize> -femit-bin=<out_binary_path>`
    return error.NotImplemented;
}
