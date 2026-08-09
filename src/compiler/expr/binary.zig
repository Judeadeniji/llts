const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const call = @import("call.zig");
const types = @import("../typecheck/from_ast.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileBinary(state: *CompilerState, bin: *const ast.Binary) !void {
    if (std.mem.eql(u8, bin.operator, "&&")) {
        try expr.compileExpression(state, bin.left);
        const end_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
        try emit.emitOp(state, .OP_POP);
        try expr.compileExpression(state, bin.right);
        emit.patchJump(state, end_jump);
        return;
    }
    if (std.mem.eql(u8, bin.operator, "||")) {
        try expr.compileExpression(state, bin.left);
        const else_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
        const end_jump = try emit.emitJump(state, .OP_JUMP);
        emit.patchJump(state, else_jump);
        try emit.emitOp(state, .OP_POP);
        try expr.compileExpression(state, bin.right);
        emit.patchJump(state, end_jump);
        return;
    }
    if (std.mem.eql(u8, bin.operator, "|>")) {
        try call.compilePipe(state, bin);
        return;
    }
    try expr.compileExpression(state, bin.left);
    try expr.compileExpression(state, bin.right);
    try emitBinOp(state, bin);
}

fn emitBinOp(state: *CompilerState, bin: *const ast.Binary) !void {
    const op = bin.operator;
    if (std.mem.eql(u8, op, "+")) {
        const str = types.isStringyType(types.resolveType(state, bin.left)) or
            types.isStringyType(types.resolveType(state, bin.right));
        try emit.emitOp(state, if (str) .OP_STRING_ADD else .OP_ADD);
    } else if (std.mem.eql(u8, op, "-")) {
        try emit.emitOp(state, .OP_SUB);
    } else if (std.mem.eql(u8, op, "*")) {
        try emit.emitOp(state, .OP_MUL);
    } else if (std.mem.eql(u8, op, "/")) {
        try emit.emitOp(state, .OP_DIV);
    } else if (std.mem.eql(u8, op, "%")) {
        try emit.emitOp(state, .OP_MOD);
    } else if (std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**")) {
        try emit.emitOp(state, .OP_POW);
    } else if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) {
        const both = types.isStringyType(types.resolveType(state, bin.left)) and
            types.isStringyType(types.resolveType(state, bin.right));
        const eq = std.mem.eql(u8, op, "==");
        if (eq) try emit.emitOp(state, if (both) .OP_STRING_EQUAL else .OP_EQUAL) else try emit.emitOp(state, if (both) .OP_STRING_NOT_EQUAL else .OP_NOT_EQUAL);
    } else if (std.mem.eql(u8, op, "<")) {
        try emit.emitOp(state, .OP_LESS);
    } else if (std.mem.eql(u8, op, "<=")) {
        try emit.emitOp(state, .OP_LESS_EQUAL);
    } else if (std.mem.eql(u8, op, ">")) {
        try emit.emitOp(state, .OP_GREATER);
    } else if (std.mem.eql(u8, op, ">=")) {
        try emit.emitOp(state, .OP_GREATER_EQUAL);
    }
}

pub fn compileUnary(state: *CompilerState, un: *const ast.Unary) !void {
    try expr.compileExpression(state, un.arg);
    if (std.mem.eql(u8, un.operator, "-")) try emit.emitOp(state, .OP_NEGATE);
    if (std.mem.eql(u8, un.operator, "!")) try emit.emitOp(state, .OP_NOT);
}
