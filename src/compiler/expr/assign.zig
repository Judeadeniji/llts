const std = @import("std");
const ast = @import("../../ast/root.zig");
const opcode = @import("../../bytecode/opcode.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const types = @import("../typecheck/from_ast.zig");

const OpCode = opcode.OpCode;
const CompilerState = state_mod.CompilerState;

pub fn compileAssignment(state: *CompilerState, assign: *const ast.Assignment) !void {
    const arith = compoundOp(assign.operator);
    if (assign.left.* == .index) {
        try assignIndex(state, &assign.left.index, assign.right, arith);
    } else if (assign.left.* == .member) {
        try assignMember(state, &assign.left.member, assign.right, arith);
    } else if (assign.left.* == .primary) {
        try assignPrimary(state, &assign.left.primary, assign.right, arith);
    }
}

fn compoundOp(op: []const u8) ?OpCode {
    if (std.mem.eql(u8, op, "+=")) return .OP_ADD;
    if (std.mem.eql(u8, op, "-=")) return .OP_SUB;
    if (std.mem.eql(u8, op, "*=")) return .OP_MUL;
    if (std.mem.eql(u8, op, "/=")) return .OP_DIV;
    if (std.mem.eql(u8, op, "%=")) return .OP_MOD;
    return null;
}

fn assignIndex(state: *CompilerState, idx: *const ast.Index, right: *ast.Node, arith: ?OpCode) !void {
    if (arith) |op| {
        try expr.compileExpression(state, idx.object);
        try expr.compileExpression(state, idx.index);
        try expr.compileExpression(state, idx.object);
        try expr.compileExpression(state, idx.index);
        try emit.emitOp(state, .OP_GET_ARRAY);
        try expr.compileExpression(state, right);
        try emit.emitOp(state, op);
    } else {
        try expr.compileExpression(state, idx.object);
        try expr.compileExpression(state, idx.index);
        try expr.compileExpression(state, right);
    }
    try emit.emitOp(state, .OP_SET_ARRAY);
}

fn assignMember(state: *CompilerState, mem: *const ast.Member, right: *ast.Node, arith: ?OpCode) !void {
    if (types.resolveType(state, mem.object)) |type_name| {
        if (state.structs.get(type_name)) |sd| {
            if (mem.property.* == .primary) {
                if (sd.offsets.get(mem.property.primary.name)) |offset| {
                    if (arith) |op| {
                        try expr.compileExpression(state, mem.object);
                        try emit.emitConstant(state, .{ .int = offset });
                        try expr.compileExpression(state, mem.object);
                        try emit.emitConstant(state, .{ .int = offset });
                        try emit.emitOp(state, .OP_GET_INDEX);
                        try expr.compileExpression(state, right);
                        try emit.emitOp(state, op);
                    } else {
                        try expr.compileExpression(state, mem.object);
                        try emit.emitConstant(state, .{ .int = offset });
                        try expr.compileExpression(state, right);
                    }
                    try emit.emitOp(state, .OP_SET_INDEX);
                    return;
                }
            }
        }
    }
    if (mem.property.* == .primary) {
        const prop = mem.property.primary.name;
        if (arith) |op| {
            try expr.compileExpression(state, mem.object);
            try emit.emitOp(state, .OP_DUP);
            try emit.emitNameGet(state, .OP_GET_PROPERTY, prop);
            try expr.compileExpression(state, right);
            try emit.emitOp(state, op);
        } else {
            try expr.compileExpression(state, mem.object);
            try expr.compileExpression(state, right);
        }
        try emit.emitNameGet(state, .OP_SET_PROPERTY, prop);
    }
}

fn assignPrimary(state: *CompilerState, prim: *const ast.Primary, right: *ast.Node, arith: ?OpCode) !void {
    if (prim.kind != .identifier and prim.kind != .register) return;
    const local_arg = scope.resolveLocal(state, prim.name);
    const is_const = if (local_arg != -1)
        state.locals.items[@intCast(local_arg)].is_const
    else
        state.global_consts.contains(prim.name);
    if (is_const) return failConst(prim.name);
    if (arith) |op| {
        try scope.resolveVariable(state, prim.name);
        try expr.compileExpression(state, right);
        try emit.emitOp(state, op);
    } else {
        try expr.compileExpression(state, right);
    }
    const arg = scope.resolveLocal(state, prim.name);
    if (arg != -1) {
        try emit.emitOp(state, .OP_SET_LOCAL);
        try emit.emitByte(state, @intCast(arg));
    } else {
        try emit.emitNameGet(state, .OP_SET_GLOBAL, prim.name);
    }
}

fn failConst(name: []const u8) error{CompileError} {
    std.debug.print("CompileError: Cannot reassign to constant variable '{s}'\n", .{name});
    return error.CompileError;
}
