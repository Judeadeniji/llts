const std = @import("std");

pub const opcode = @import("bytecode/opcode.zig");
pub const value = @import("bytecode/value.zig");
pub const chunk = @import("bytecode/chunk.zig");
pub const disasm = @import("bytecode/disasm.zig");
pub const serialize = @import("bytecode/serialize.zig");
pub const vm_state = @import("vm/state.zig");
pub const vm_stack = @import("vm/stack.zig");
pub const execute = @import("vm/execute/root.zig");
pub const scanner = @import("scanner/root.zig");
pub const ast = @import("ast/root.zig");
pub const parser = @import("parser/root.zig");
pub const pipeline = @import("pipeline.zig");
pub const io = @import("io/root.zig");
pub const diag = @import("errors/diag.zig");

pub const OpCode = opcode.OpCode;
pub const Value = value.Value;
pub const Chunk = chunk.Chunk;
pub const VMState = vm_state.VMState;
pub const Document = ast.Document;
pub const RunOptions = pipeline.RunOptions;

/// Run a pre-built chunk (Phase 0 smoke / CO-RE bytecode load).
pub fn runChunk(
    allocator: std.mem.Allocator,
    c: *Chunk,
    source_path: []const u8,
    source_args: []const []const u8,
    max_memory_slots: usize,
) !void {
    try pipeline.runChunk(allocator, c, source_path, source_args, max_memory_slots);
}

pub fn writeBytecodeFile(allocator: std.mem.Allocator, c: *const Chunk, path: []const u8) !void {
    try pipeline.writeBytecodeFile(allocator, c, path);
}

pub fn readBytecodeFile(allocator: std.mem.Allocator, path: []const u8) !Chunk {
    return try pipeline.readBytecodeFile(allocator, path);
}

pub fn runBytecodeFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    source_args: []const []const u8,
    max_memory_slots: usize,
) !void {
    try pipeline.runBytecodeFile(allocator, path, source_args, max_memory_slots);
}

pub fn runSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !void {
    try pipeline.runSource(allocator, path, source, options);
}

pub fn compileSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !Chunk {
    return try pipeline.compileSource(allocator, path, source, options);
}

test {
    _ = opcode;
    _ = value;
    _ = chunk;
    _ = disasm;
    _ = serialize;
    _ = scanner;
    _ = ast;
    _ = parser;
    _ = pipeline;
    _ = vm_state;
}
