const state_mod = @import("state.zig");
const opcode = @import("../bytecode/opcode.zig");
const value = @import("../bytecode/value.zig");

const CompilerState = state_mod.CompilerState;
const OpCode = opcode.OpCode;
const Value = value.Value;

pub fn emitByte(state: *CompilerState, byte: u8) !void {
    try state.chunk.write(byte);
}

pub fn emitOp(state: *CompilerState, op: OpCode) !void {
    try state.chunk.writeOp(op);
}

pub fn emitConstant(state: *CompilerState, v: Value) !void {
    const idx = try state.chunk.addConstant(v);
    try emitOp(state, .OP_CONSTANT);
    try emitByte(state, idx);
}

pub fn emitString(state: *CompilerState, s: []const u8) !void {
    const idx = try state.chunk.addStringConstant(s);
    try emitOp(state, .OP_CONSTANT);
    try emitByte(state, idx);
    try emitOp(state, .OP_MAKE_STRING);
}

pub fn emitNameGet(state: *CompilerState, op: OpCode, name: []const u8) !void {
    const idx = try state.chunk.addStringConstant(name);
    try emitOp(state, op);
    try emitByte(state, idx);
}

pub fn emitJump(state: *CompilerState, op: OpCode) !usize {
    try emitOp(state, op);
    try emitByte(state, 0xff);
    try emitByte(state, 0xff);
    return state.chunk.code.items.len - 2;
}

pub fn patchJump(state: *CompilerState, offset: usize) void {
    const jump = state.chunk.code.items.len - offset - 2;
    if (jump > 0xffff) unreachable;
    state.chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
    state.chunk.code.items[offset + 1] = @intCast(jump & 0xff);
}

pub fn emitLoop(state: *CompilerState, loop_start: usize) !void {
    try emitOp(state, .OP_LOOP);
    const offset = state.chunk.code.items.len - loop_start + 2;
    if (offset > 0xffff) unreachable;
    try emitByte(state, @intCast((offset >> 8) & 0xff));
    try emitByte(state, @intCast(offset & 0xff));
}

pub fn emitCallStatic(state: *CompilerState, addr: u16, argc: u8) !void {
    try emitOp(state, .OP_CALL_STATIC);
    try emitByte(state, @intCast((addr >> 8) & 0xff));
    try emitByte(state, @intCast(addr & 0xff));
    try emitByte(state, argc);
}

pub fn emitLine(state: *CompilerState, line: u32) !void {
    if (!state.debug) return;
    try emitOp(state, .OP_LINE);
    try emitByte(state, @intCast((line >> 8) & 0xff));
    try emitByte(state, @intCast(line & 0xff));
}

pub fn emitLineIfNeeded(state: *CompilerState, line: u32) !void {
    if (!state.debug) return;
    const as_i: i32 = @intCast(line);
    if (state.last_emitted_line == as_i) return;
    state.last_emitted_line = as_i;
    try emitLine(state, line);
}
