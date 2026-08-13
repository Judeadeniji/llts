const std = @import("std");
const scanner = @import("scanner/root.zig");
const parser = @import("parser/root.zig");
const compiler = @import("compiler/root.zig");
const chunk_mod = @import("bytecode/chunk.zig");
const serialize = @import("bytecode/serialize.zig");
const vm_state = @import("vm/state.zig");
const execute = @import("vm/execute/root.zig");
const builtins = @import("vm/builtins/root.zig");

pub const RunOptions = struct {
    debug: bool = true,
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

pub fn runChunk(allocator: std.mem.Allocator, chunk: *chunk_mod.Chunk, script_path: []const u8) !void {
    var state = try vm_state.VMState.init(allocator, chunk);
    defer state.deinit();
    state.script_path = script_path;
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
    try runChunk(allocator, &chunk, path);
}

pub fn writeBytecodeFile(allocator: std.mem.Allocator, chunk: *const chunk_mod.Chunk, path: []const u8) !void {
    try serialize.writeFile(allocator, chunk, path);
}

pub fn readBytecodeFile(allocator: std.mem.Allocator, path: []const u8) !chunk_mod.Chunk {
    return try serialize.readFile(allocator, path);
}

pub fn runBytecodeFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var chunk = try readBytecodeFile(allocator, path);
    defer chunk.deinit();
    try runChunk(allocator, &chunk, path);
}
