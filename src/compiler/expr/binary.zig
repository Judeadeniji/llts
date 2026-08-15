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
    if (try foldStringConcat(state, bin)) {
        return;
    }
    try expr.compileExpression(state, bin.left);
    try expr.compileExpression(state, bin.right);
    try emitBinOp(state, bin);
}

fn foldStringConcat(state: *CompilerState, bin: *const ast.Binary) !bool {
    if (!std.mem.eql(u8, bin.operator, "+")) return false;
    // Use an arena so that intermediate allocations don't leak, and the final string is cleaned up
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const str = try extractConstantString(arena.allocator(), @as(*const ast.Node, @ptrCast(bin)));
    if (str) |s| {
        try emit.emitString(state, s);
        return true;
    }
    return false;
}

fn extractConstantString(allocator: std.mem.Allocator, node: *const ast.Node) anyerror!?[]const u8 {
    switch (node.*) {
        .literal => |lit| {
            if (lit.literal_type == .string) return lit.value;
            return null;
        },
        .binary => |b| {
            if (std.mem.eql(u8, b.operator, "+")) {
                const left = try extractConstantString(allocator, b.left) orelse return null;
                const right = try extractConstantString(allocator, b.right) orelse return null;
                return try std.mem.concat(allocator, u8, &.{ left, right });
            }
            return null;
        },
        else => return null,
    }
}

fn emitBinOp(state: *CompilerState, bin: *const ast.Binary) !void {
    const op = bin.operator;
    const both_int = isIntType(types.resolveType(state, bin.left)) and isIntType(types.resolveType(state, bin.right));
    if (std.mem.eql(u8, op, "+")) {
        const str = types.isStringyType(types.resolveType(state, bin.left)) or
            types.isStringyType(types.resolveType(state, bin.right));
        if (str) {
            try emit.emitOp(state, .OP_STRING_ADD);
        } else if (both_int) {
            try emit.emitOp(state, .OP_ADD_I64);
        } else {
            try emit.emitOp(state, .OP_ADD);
        }
    } else if (std.mem.eql(u8, op, "-")) {
        try emit.emitOp(state, if (both_int) .OP_SUB_I64 else .OP_SUB);
    } else if (std.mem.eql(u8, op, "*")) {
        try emit.emitOp(state, if (both_int) .OP_MUL_I64 else .OP_MUL);
    } else if (std.mem.eql(u8, op, "/")) {
        try emit.emitOp(state, .OP_DIV);
    } else if (std.mem.eql(u8, op, "%")) {
        try emit.emitOp(state, .OP_MOD);
    } else if (std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**")) {
        try emit.emitOp(state, .OP_POW);
    } else if (std.mem.eql(u8, op, "&")) {
        try emit.emitOp(state, .OP_BIT_AND);
    } else if (std.mem.eql(u8, op, "|")) {
        try emit.emitOp(state, .OP_BIT_OR);
    } else if (std.mem.eql(u8, op, "~")) {
        try emit.emitOp(state, .OP_BIT_XOR);
    } else if (std.mem.eql(u8, op, "<<")) {
        try emit.emitOp(state, .OP_SHL);
    } else if (std.mem.eql(u8, op, ">>")) {
        try emit.emitOp(state, .OP_SHR);
    } else if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) {
        const both = types.isStringyType(types.resolveType(state, bin.left)) and
            types.isStringyType(types.resolveType(state, bin.right));
        const eq = std.mem.eql(u8, op, "==");
        if (eq) try emit.emitOp(state, if (both) .OP_STRING_EQUAL else .OP_EQUAL) else try emit.emitOp(state, if (both) .OP_STRING_NOT_EQUAL else .OP_NOT_EQUAL);
    } else if (std.mem.eql(u8, op, "<")) {
        try emit.emitOp(state, if (both_int) .OP_LT_I64 else .OP_LESS);
    } else if (std.mem.eql(u8, op, "<=")) {
        try emit.emitOp(state, .OP_LESS_EQUAL);
    } else if (std.mem.eql(u8, op, ">")) {
        try emit.emitOp(state, .OP_GREATER);
    } else if (std.mem.eql(u8, op, ">=")) {
        try emit.emitOp(state, .OP_GREATER_EQUAL);
    }
}

fn isIntType(t: ?[]const u8) bool {
    const s = t orelse return false;
    return std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "i32") or std.mem.eql(u8, s, "i64") or std.mem.eql(u8, s, "number");
}

pub fn compileUnary(state: *CompilerState, un: *const ast.Unary) !void {
    try expr.compileExpression(state, un.arg);
    // `&` is type-level only for struct handles (identity at runtime).
    if (std.mem.eql(u8, un.operator, "-")) try emit.emitOp(state, .OP_NEGATE);
    if (std.mem.eql(u8, un.operator, "!")) try emit.emitOp(state, .OP_NOT);
    if (std.mem.eql(u8, un.operator, "~")) try emit.emitOp(state, .OP_BIT_NOT);
}
