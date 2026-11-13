const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const call = @import("call.zig");
const types = @import("../typecheck/from_ast.zig");
const ir = @import("../typecheck/ir.zig");
const widths = @import("../widths.zig");
const scope = @import("../scope.zig");
const compile_errors = @import("../../errors/compile.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileBinary(state: *CompilerState, bin: *const ast.Binary) !void {
    if (state.type_eq_folds.get(bin.left)) |same| {
        try emit.emitOp(state, if (same) .OP_TRUE else .OP_FALSE);
        return;
    }
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
    if (std.mem.eql(u8, bin.operator, "??")) {
        // Null-coalescing: if left is non-null use it, else evaluate right.
        // Stack effect: push one value regardless of which branch is taken.
        try expr.compileExpression(state, bin.left);
        try emit.emitOp(state, .OP_DUP);
        // Jump past the POP+right-eval if the value is NOT null.
        const not_null_jump = try emit.emitJump(state, .OP_JUMP_IF_NULL);
        // Value is not null: jump over the right-side branch.
        const end_jump = try emit.emitJump(state, .OP_JUMP);
        emit.patchJump(state, not_null_jump);
        // Value was null: discard the null duplicate and evaluate the right side.
        try emit.emitOp(state, .OP_POP);
        try expr.compileExpression(state, bin.right);
        emit.patchJump(state, end_jump);
        return;
    }
    if (try foldStringConcat(state, bin)) {
        return;
    }
    const locals_before = state.locals.items.len;
    try expr.compileExpression(state, bin.left);
    // Claim left (and any temps under it) as anonymous locals so a value `@if`
    // / labeled block on the right does not clobber them via SET_LOCAL into the
    // wrong slot (`"r=" + (@if …)`).
    try scope.claimStackTemps(state);
    const left_claims = state.locals.items.len - locals_before;
    try expr.compileExpression(state, bin.right);
    try emitBinOp(state, bin);
    // Binop consumed left; drop its claim(s) (no OP_POP — value already gone).
    scope.dropLocalEntries(state, left_claims);
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

/// Canonical width for an operand: recorded IR first, display only when the
/// emitter has no recorded type (emit-only paths).
fn widthOf(state: *CompilerState, node: *ast.Node) ?widths.Width {
    if (state.type_ir_of_results.get(node)) |t| {
        switch (ir.peelDefined(t)) {
            .u1 => return .u1,
            .i8 => return .i8,
            .i16 => return .i16,
            .i32 => return .i32,
            .i64 => return .i64,
            .u8 => return .u8,
            .u16 => return .u16,
            .u32 => return .u32,
            .u64 => return .u64,
            .f32 => return .f32,
            .f64 => return .f64,
            .isize => return .isize,
            .usize => return .usize,
            .fsize => return .fsize,
            else => {},
        }
    }
    const disp = state.type_of_results.get(node) orelse types.resolveType(state, node) orelse return null;
    return widths.fromName(disp);
}

/// `string` / `[]u8` / `[N]u8`-like operands select the string opcodes.
fn isStringyNode(state: *CompilerState, node: *ast.Node) bool {
    if (state.type_ir_of_results.get(node)) |t| {
        return switch (ir.peelDefined(t)) {
            .struct_ => |n| std.mem.eql(u8, n, "string"),
            .array => |a| isByteElem(a.elem.*),
            else => false,
        };
    }
    const disp = state.type_of_results.get(node) orelse types.resolveType(state, node);
    return types.isStringyType(disp);
}

fn isByteElem(t: ir.Type) bool {
    return switch (ir.peelDefined(t)) {
        .u8 => true,
        .struct_ => |n| std.mem.eql(u8, n, "byte"),
        else => false,
    };
}

fn emitBinOp(state: *CompilerState, bin: *const ast.Binary) !void {
    const op = bin.operator;
    const l_width = widthOf(state, bin.left);
    const r_width = widthOf(state, bin.right);
    const both_int = l_width != null and !l_width.?.isFloat() and r_width != null and !r_width.?.isFloat();

    if (std.mem.eql(u8, op, "+")) {
        const str = isStringyNode(state, bin.left) or isStringyNode(state, bin.right);
        if (str) {
            try emit.emitOp(state, .OP_STRING_ADD);
        } else if (both_int) {
            try emit.emitOp(state, .OP_ADD_TYPED);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_ADD);
        }
    } else if (std.mem.eql(u8, op, "+%")) {
        // Wrapping add: never traps, two's-complement wrap on overflow.
        if (both_int) {
            try emit.emitOp(state, .OP_ADD_TYPED_WRAP);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_ADD_WRAP);
        }
    } else if (std.mem.eql(u8, op, "-")) {
        if (both_int) {
            try emit.emitOp(state, .OP_SUB_TYPED);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_SUB);
        }
    } else if (std.mem.eql(u8, op, "-%")) {
        if (both_int) {
            try emit.emitOp(state, .OP_SUB_TYPED_WRAP);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_SUB_WRAP);
        }
    } else if (std.mem.eql(u8, op, "*")) {
        if (both_int) {
            try emit.emitOp(state, .OP_MUL_TYPED);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_MUL);
        }
    } else if (std.mem.eql(u8, op, "*%")) {
        if (both_int) {
            try emit.emitOp(state, .OP_MUL_TYPED_WRAP);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_MUL_WRAP);
        }
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
        const both = isStringyNode(state, bin.left) and isStringyNode(state, bin.right);
        const eq = std.mem.eql(u8, op, "==");
        if (eq) try emit.emitOp(state, if (both) .OP_STRING_EQUAL else .OP_EQUAL) else try emit.emitOp(state, if (both) .OP_STRING_NOT_EQUAL else .OP_NOT_EQUAL);
    } else if (std.mem.eql(u8, op, "<")) {
        if (both_int) {
            try emit.emitOp(state, .OP_LT_TYPED);
            try emit.emitByte(state, @intFromEnum(l_width.?));
        } else {
            try emit.emitOp(state, .OP_LESS);
        }
    } else if (std.mem.eql(u8, op, "<=")) {
        try emit.emitOp(state, .OP_LESS_EQUAL);
    } else if (std.mem.eql(u8, op, ">")) {
        try emit.emitOp(state, .OP_GREATER);
    } else if (std.mem.eql(u8, op, ">=")) {
        try emit.emitOp(state, .OP_GREATER_EQUAL);
    }
}

pub fn compileUnary(state: *CompilerState, un: *const ast.Unary) !void {
    if (std.mem.eql(u8, un.operator, "&")) {
        if (scope.constPlaceRoot(state, un.arg)) |name| {
            return compile_errors.compileFailFmt(state, "Cannot take the address of constant '{s}'", .{name});
        }
    }
    try expr.compileExpression(state, un.arg);
    // `&` is type-level only for aggregate handles (identity at runtime).
    if (std.mem.eql(u8, un.operator, "-")) try emit.emitOp(state, .OP_NEGATE);
    if (std.mem.eql(u8, un.operator, "!")) try emit.emitOp(state, .OP_NOT);
    if (std.mem.eql(u8, un.operator, "~")) try emit.emitOp(state, .OP_BIT_NOT);
}
