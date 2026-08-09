const std = @import("std");

pub const opcode = @import("bytecode/opcode.zig");
pub const value = @import("bytecode/value.zig");
pub const chunk = @import("bytecode/chunk.zig");
pub const vm_state = @import("vm/state.zig");
pub const vm_stack = @import("vm/stack.zig");
pub const execute = @import("vm/execute/root.zig");
pub const scanner = @import("scanner/root.zig");
pub const ast = @import("ast/root.zig");
pub const parser = @import("parser/root.zig");
pub const pipeline = @import("pipeline.zig");

pub const OpCode = opcode.OpCode;
pub const Value = value.Value;
pub const Chunk = chunk.Chunk;
pub const VMState = vm_state.VMState;
pub const Document = ast.Document;
pub const RunOptions = pipeline.RunOptions;

/// Run a pre-built chunk (Phase 0 smoke / later compiler output).
pub fn runChunk(allocator: std.mem.Allocator, c: *Chunk) !void {
    var state = try VMState.init(allocator, c);
    defer state.deinit();
    try execute.execute(&state, 0);
}

pub fn runSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !void {
    try pipeline.runSource(allocator, path, source, options);
}

test {
    _ = opcode;
    _ = value;
    _ = chunk;
    _ = scanner;
    _ = ast;
    _ = parser;
    _ = pipeline;
}
