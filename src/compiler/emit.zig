const state_mod = @import("state.zig");
const opcode = @import("../bytecode/opcode.zig");
const value = @import("../bytecode/value.zig");
const scope = @import("scope.zig");

const CompilerState = state_mod.CompilerState;
const OpCode = opcode.OpCode;
const Value = value.Value;

pub fn emitByte(state: *CompilerState, byte: u8) !void {
    try state.chunk.write(byte);
}

pub fn emitOp(state: *CompilerState, op: OpCode) !void {
    applyStackEffect(state, op);
    try state.chunk.writeOp(op);
}

/// Keep `state.stack_depth` aligned with VM stack effects for fixed-arity ops.
/// Variable-arity ops (`OP_CALL`, `OP_PRINT`, …) adjust depth at their emit site.
fn applyStackEffect(state: *CompilerState, op: OpCode) void {
    switch (op) {
        .OP_CONSTANT, .OP_NULL, .OP_TRUE, .OP_FALSE, .OP_VOID, .OP_DUP, .OP_GET_LOCAL, .OP_GET_GLOBAL, .OP_GET_FUNCTION, .OP_GET_MODULE => scope.notePush(state),
        .OP_POP, .OP_JUMP_IF_FALSE => scope.notePop(state),
        // pop2 push1
        .OP_ADD, .OP_ADD_WRAP, .OP_STRING_ADD, .OP_SUB, .OP_SUB_WRAP, .OP_MUL, .OP_MUL_WRAP, .OP_DIV, .OP_MOD, .OP_POW, .OP_EQUAL, .OP_NOT_EQUAL, .OP_STRING_EQUAL, .OP_STRING_NOT_EQUAL, .OP_LESS, .OP_LESS_EQUAL, .OP_GREATER, .OP_GREATER_EQUAL, .OP_BIT_AND, .OP_BIT_OR, .OP_BIT_XOR, .OP_SHL, .OP_SHR, .OP_ADD_TYPED, .OP_SUB_TYPED, .OP_MUL_TYPED, .OP_LT_TYPED, .OP_ADD_TYPED_WRAP, .OP_SUB_TYPED_WRAP, .OP_MUL_TYPED_WRAP => scope.notePop(state),
        // in-place / pop1 push1 (net 0)
        .OP_MAKE_STRING, .OP_MAKE_ERROR, .OP_MAKE_ERROR_PAYLOAD, .OP_NEGATE, .OP_NOT, .OP_BIT_NOT, .OP_IS_ERROR, .OP_SET_LOCAL, .OP_SET_GLOBAL, .OP_MARK_CONST, .OP_ASSERT_TYPE, .OP_AS, .OP_ADDR_OF, .OP_ERROR_NAME, .OP_GET_PROPERTY, .OP_LOAD_FIELD, .OP_JUMP, .OP_JUMP_IF_NULL, .OP_LOOP, .OP_LINE, .OP_SOURCE, .OP_RETURN, .OP_IMPORT, .OP_SIZEOF, .OP_FOR_PREP, .OP_FOR_LOOP, .OP_PACK_REST => {},
        // pop2 push1
        .OP_GET_INDEX, .OP_GET_ARRAY, .OP_GET_ARRAY_OR_NULL => scope.notePop(state),
        // pop3 push1
        .OP_SLICE => scope.notePopN(state, 2),
        // pop2 (no push)
        .OP_SET_INDEX, .OP_SET_ARRAY, .OP_SET_PROPERTY, .OP_STORE_FIELD => scope.notePopN(state, 2),
        // Variable arity — caller adjusts.
        .OP_CALL, .OP_CALL_STATIC, .OP_PRINT => {},
    }
}

pub fn emitShort(state: *CompilerState, short: u16) !void {
    try state.chunk.write(@intCast((short >> 8) & 0xff));
    try state.chunk.write(@intCast(short & 0xff));
}

pub fn emitConstant(state: *CompilerState, v: Value) !void {
    const idx = try state.chunk.addConstant(v);
    try emitOp(state, .OP_CONSTANT);
    try emitShort(state, idx);
}

pub fn emitString(state: *CompilerState, s: []const u8) !void {
    const idx = try state.chunk.addStringConstant(s);
    try emitOp(state, .OP_CONSTANT);
    try emitShort(state, idx);
    try emitOp(state, .OP_MAKE_STRING);
}

pub fn emitNameGet(state: *CompilerState, op: OpCode, name: []const u8) !void {
    if (op == .OP_GET_GLOBAL or op == .OP_SET_GLOBAL) {
        const slot = try internGlobal(state, name);
        try emitOp(state, op);
        try emitShort(state, slot);
        return;
    }
    const idx = try state.chunk.addStringConstant(name);
    try emitOp(state, op);
    try emitShort(state, idx);
}

fn internGlobal(state: *CompilerState, name: []const u8) !u16 {
    if (state.global_slots.get(name)) |slot| return slot;
    const slot = try state.chunk.internGlobalName(name);
    try state.global_slots.put(name, slot);
    return slot;
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

/// Packed struct field load/store: u16 byte offset + u8 FieldKind.
pub fn emitLoadField(state: *CompilerState, offset: i32, kind: u8) !void {
    try emitOp(state, .OP_LOAD_FIELD);
    try emitShort(state, @intCast(offset));
    try emitByte(state, kind);
}

pub fn emitStoreField(state: *CompilerState, offset: i32, kind: u8) !void {
    try emitOp(state, .OP_STORE_FIELD);
    try emitShort(state, @intCast(offset));
    try emitByte(state, kind);
}

pub fn noteLoc(state: *CompilerState, line: u32, column: u32, path: []const u8) void {
    if (line > 0) state.diag_line = line;
    if (column > 0) state.diag_column = column;
    if (path.len > 0) state.diag_path = path;
}

pub fn emitLine(state: *CompilerState, line: u32, column: u32) !void {
    noteLoc(state, line, column, "");
    if (!state.debug) return;
    try emitOp(state, .OP_LINE);
    try emitByte(state, @intCast((line >> 8) & 0xff));
    try emitByte(state, @intCast(line & 0xff));
    try emitByte(state, @intCast((column >> 8) & 0xff));
    try emitByte(state, @intCast(column & 0xff));
}

pub fn emitSource(state: *CompilerState, source_index: u16) !void {
    const sf = state.chunk.sourceAt(source_index);
    if (sf.path.len > 0) state.diag_path = sf.path;
    if (!state.debug) return;
    try emitOp(state, .OP_SOURCE);
    try emitByte(state, @intCast((source_index >> 8) & 0xff));
    try emitByte(state, @intCast(source_index & 0xff));
}

pub fn emitLineIfNeeded(state: *CompilerState, line: u32, column: u32) !void {
    noteLoc(state, line, column, "");
    if (!state.debug) return;
    const as_i: i32 = @intCast(line);
    const as_c: i32 = @intCast(column);
    if (state.last_emitted_line == as_i and state.last_emitted_column == as_c) return;
    state.last_emitted_line = as_i;
    state.last_emitted_column = as_c;
    try emitLine(state, line, column);
}
