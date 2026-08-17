const std = @import("std");
const ast = @import("../../ast/root.zig");
const opcode = @import("../../bytecode/opcode.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const types = @import("../typecheck/from_ast.zig");
const widths = @import("../widths.zig");
const compile_errors = @import("../../errors/compile.zig");

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
    if (std.mem.eql(u8, op, "&=")) return .OP_BIT_AND;
    if (std.mem.eql(u8, op, "|=")) return .OP_BIT_OR;
    if (std.mem.eql(u8, op, "~=")) return .OP_BIT_XOR;
    if (std.mem.eql(u8, op, "<<=")) return .OP_SHL;
    if (std.mem.eql(u8, op, ">>=")) return .OP_SHR;
    return null;
}

fn assignIndex(state: *CompilerState, idx: *const ast.Index, right: *ast.Node, arith: ?OpCode) !void {
    if (idx.is_slice) {
        return compile_errors.compileFailFmt(state, "Cannot assign to a slice view", .{});
    }
    const start = idx.index orelse {
        return compile_errors.compileFailFmt(state, "Expected index expression", .{});
    };
    if (arith) |op| {
        try expr.compileExpression(state, idx.object);
        try expr.compileExpression(state, start);
        try expr.compileExpression(state, idx.object);
        try expr.compileExpression(state, start);
        try emit.emitOp(state, .OP_GET_ARRAY);
        try expr.compileExpression(state, right);
        try emit.emitOp(state, op);
    } else {
        try expr.compileExpression(state, idx.object);
        try expr.compileExpression(state, start);
        try expr.compileExpression(state, right);
    }
    if (types.resolveType(state, idx.object)) |tn| {
        if (types.isStringyType(tn) or std.mem.endsWith(u8, tn, "byte")) {
            try emit.emitOp(state, .OP_AS);
            try emit.emitByte(state, @intFromEnum(widths.Width.u8));
        }
    }
    try emit.emitOp(state, .OP_SET_ARRAY);
}

fn assignMember(state: *CompilerState, mem: *const ast.Member, right: *ast.Node, arith: ?OpCode) !void {
    // Tuple field `.0` / `.1`
    if (mem.property.* == .primary) {
        if (std.fmt.parseInt(i64, mem.property.primary.name, 10)) |idx| {
            if (arith) |op| {
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = idx });
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = idx });
                try emit.emitOp(state, .OP_GET_ARRAY);
                try expr.compileExpression(state, right);
                try emit.emitOp(state, op);
            } else {
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = idx });
                try expr.compileExpression(state, right);
            }
            try emit.emitOp(state, .OP_SET_ARRAY);
            return;
        } else |_| {}
    }
    if (types.resolveType(state, mem.object)) |type_name| {
        if (mem.property.* == .primary) {
            if (types.lookupStructField(state, type_name, mem.property.primary.name)) |info| {
                const layout = @import("../layout.zig");
                const kind: u8 = @intFromEnum(layout.fieldKind(state, info.field_ty));
                if (arith) |op| {
                    try expr.compileExpression(state, mem.object);
                    try emit.emitOp(state, .OP_DUP);
                    try emit.emitLoadField(state, info.offset, kind);
                    try expr.compileExpression(state, right);
                    try emit.emitOp(state, op);
                } else {
                    try expr.compileExpression(state, mem.object);
                    try expr.compileExpression(state, right);
                }
                if (layout.widthFromFieldKind(@enumFromInt(kind))) |w| {
                    try emit.emitOp(state, .OP_AS);
                    try emit.emitByte(state, @intFromEnum(w));
                }
                try emit.emitStoreField(state, info.offset, kind);
                return;
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
    if (is_const) return failConst(state, prim.name);
    if (arith) |op| {
        try scope.resolveVariable(state, prim.name);
        try expr.compileExpression(state, right);
        try emit.emitOp(state, op);
    } else {
        try expr.compileExpression(state, right);
    }
    if (local_arg != -1) {
        if (state.locals.items[@intCast(local_arg)].type_name) |tn| {
            if (widthCastKindName(tn)) |kind| {
                try emit.emitOp(state, .OP_AS);
                try emit.emitByte(state, kind);
            }
        }
    } else if (state.global_types.get(prim.name)) |tn| {
        if (widthCastKindName(tn)) |kind| {
            try emit.emitOp(state, .OP_AS);
            try emit.emitByte(state, kind);
        }
    }
    const arg = scope.resolveLocal(state, prim.name);
    if (arg != -1) {
        // Track region so `return t` after `$t = Foo{}` vs `@new(a, Foo{})` is checked.
        state.locals.items[@intCast(arg)].alloc_region = @import("../escape.zig").regionOfRhs(state, right);
        try emit.emitOp(state, .OP_SET_LOCAL);
        try emit.emitByte(state, @intCast(arg));
    } else {
        try emit.emitNameGet(state, .OP_SET_GLOBAL, prim.name);
    }
}

fn failConst(state: *CompilerState, name: []const u8) error{CompileError} {
    return compile_errors.compileFailFmt(state, "Cannot reassign to constant variable '{s}'", .{name});
}

fn widthCastKindName(tn: []const u8) ?u8 {
    if (widths.fromName(tn)) |w| return @intFromEnum(w);
    return null;
}
