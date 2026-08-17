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

pub const RunOptions = struct {
    debug: bool = true,
    /// Extra argv forwarded to `os.args()` as argv[1..] (argv[0] is the script path).
    script_args: []const []const u8 = &.{},
    max_memory_slots: usize = 1048576,
};

pub const EmitLlvmOptions = struct {
    debug: bool = true,
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

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source);
    defer doc.deinit();

    return try compiler.compile(allocator, &doc, .{ .debug = options.debug });
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
    try execute.execute(&state, 0);
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

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source);
    defer doc.deinit();

    var state = try compiler.analyze(allocator, &doc, .{ .debug = options.debug });
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
