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
const path = @import("path.zig");
const layout = @import("../layout.zig");

const OpCode = opcode.OpCode;
const CompilerState = state_mod.CompilerState;

pub fn compileAssignment(state: *CompilerState, assign: *const ast.Assignment) !void {
    const arith = compoundOp(assign.operator);
    if (assign.left.* == .index) {
        try assignIndex(state, &assign.left.index, assign.right, arith);
    } else if (assign.left.* == .member) {
        try assignMember(state, &assign.left.member, assign.left, assign.right, arith);
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

fn isConstBinding(state: *CompilerState, name: []const u8) bool {
    const local_arg = scope.resolveLocal(state, name);
    if (local_arg != -1) {
        return state.locals.items[@intCast(local_arg)].is_const;
    }
    if (state.global_consts.contains(name)) return true;
    if (name.len > 0 and name[0] == '$' and state.global_consts.contains(name[1..])) return true;
    return false;
}

fn assignIndex(state: *CompilerState, idx: *const ast.Index, right: *ast.Node, arith: ?OpCode) !void {
    if (idx.is_slice) {
        return compile_errors.compileFailFmt(state, "Cannot assign to a slice view", .{});
    }
    if (idx.object.* == .primary) {
        const name = idx.object.primary.name;
        if (isConstBinding(state, name)) {
            return compile_errors.compileFailFmt(state, "Cannot mutate elements of constant '{s}'", .{name});
        }
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

fn assignMember(state: *CompilerState, mem: *const ast.Member, node: *ast.Node, right: *ast.Node, arith: ?OpCode) !void {
    if (try path.tryResolveStaticPath(state, node)) |static_path| {
        if (state.global_consts.contains(static_path)) {
            return compile_errors.compileFailFmt(state, "Cannot assign to constant '{s}'", .{static_path});
        }
        if (!state.global_vars.contains(static_path)) {
            return compile_errors.compileFailFmt(state, "Cannot assign to member '{s}' of imported module", .{mem.property.primary.name});
        }
        try assignStaticGlobal(state, static_path, right, arith);
        return;
    }

    if (mem.object.* == .primary) {
        const name = mem.object.primary.name;
        if (isConstBinding(state, name)) {
            return compile_errors.compileFailFmt(state, "Cannot mutate field of constant '{s}'", .{name});
        }
    }

    // Tuple field `.0` / `.1`
    if (mem.property.* == .primary) {
        if (std.fmt.parseInt(i64, mem.property.primary.name, 10)) |idx| {
            if (arith) |op| {
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = idx });
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = idx });
                try emit.emitLineIfNeeded(state, mem.loc.line, mem.loc.column);
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
        if (std.mem.startsWith(u8, type_name, "module:")) {
            const mod_path = type_name["module:".len..];
            // Exported *mutable* globals stay assignable across modules
            // (`internal.defaultOutput = bridge`); every other namespace member
            // is read-only. Keep this in sync with typecheck's assignment path.
            if (mem.property.* == .primary and path.moduleMemberIsMutableGlobal(state, mod_path, mem.property.primary.name)) {
                const key = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_path, mem.property.primary.name });
                try state.owned.append(state.allocator, key);
                try assignStaticGlobal(state, key, right, arith);
                return;
            }
            return compile_errors.compileFailFmt(
                state,
                "Cannot assign to member '{s}' of imported module '{s}'",
                .{ mem.property.primary.name, mod_path },
            );
        }
        if (mem.property.* == .primary) {
            if (types.lookupStructField(state, type_name, mem.property.primary.name)) |info| {
                const kind: u8 = @intFromEnum(layout.fieldKind(state, info.field_ty));
                if (arith) |op| {
                    try expr.compileExpression(state, mem.object);
                    try emit.emitOp(state, .OP_DUP);
                    try emit.emitLineIfNeeded(state, mem.loc.line, mem.loc.column);
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
            } else {
                return compile_errors.compileFailFmt(
                    state,
                    "Field '{s}' does not exist on '{s}'",
                    .{ mem.property.primary.name, type_name },
                );
            }
        }
    }
    if (mem.property.* == .primary) {
        const prop = mem.property.primary.name;
        if (std.fmt.parseInt(i64, prop, 10) catch null) |ci| {
            if (arith) |op| {
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = ci });
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = ci });
                try emit.emitOp(state, .OP_GET_ARRAY);
                try expr.compileExpression(state, right);
                try emit.emitOp(state, op);
                try emit.emitOp(state, .OP_SET_ARRAY);
                return;
            } else {
                try expr.compileExpression(state, mem.object);
                try emit.emitConstant(state, .{ .i64 = ci });
                try expr.compileExpression(state, right);
                try emit.emitOp(state, .OP_SET_ARRAY);
                return;
            }
        }
        if (path.tryResolveStaticPath(state, mem.object) catch null) |sp| {
            if (types.resolveType(state, mem.object)) |t| {
                if (std.mem.startsWith(u8, t, "module:")) {
                    return compile_errors.compileFailFmt(
                        state,
                        "Cannot assign to member '{s}' of imported module '{s}'",
                        .{ prop, sp },
                    );
                }
            }
        }
        return compile_errors.compileFailFmt(
            state,
            "Cannot assign field '{s}' on non-struct target",
            .{prop},
        );
    }
}

/// Store to a module-qualified global by name (`<mod>::<member>`).
fn assignStaticGlobal(state: *CompilerState, key: []const u8, right: *ast.Node, arith: ?OpCode) !void {
    if (arith) |op| {
        try emit.emitNameGet(state, .OP_GET_GLOBAL, key);
        try expr.compileExpression(state, right);
        try emit.emitOp(state, op);
    } else {
        try expr.compileExpression(state, right);
    }
    try emit.emitNameGet(state, .OP_SET_GLOBAL, key);
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
    if (widths.fromName(tn)) |w| {
        if (w == .i64 or w == .isize or w == .f64 or w == .fsize) return null;
        return @intFromEnum(w);
    }
    return null;
}
