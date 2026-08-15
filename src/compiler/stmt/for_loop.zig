const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const stmt = @import("root.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileFor(state: *CompilerState, for_expr: *const ast.For) !void {
    try scope.beginScope(state);
    try state.loops.append(state.allocator, .{
        .label = for_expr.label,
        .scope_depth = state.scope_depth,
    });

    if (for_expr.captures.len > 0) {
        if (for_expr.expr.* == .binary and std.mem.eql(u8, for_expr.expr.binary.operator, "..")) {
            try compileRangeFor(state, for_expr);
        } else {
            try compileIterFor(state, for_expr);
        }
    } else {
        try compileCondFor(state, for_expr);
    }

    try scope.endScope(state);
}

fn bodyBlock(state: *CompilerState, for_expr: *const ast.For) !*const ast.Block {
    return switch (for_expr.body.*) {
        .block => |*b| b,
        else => @import("../../errors/compile.zig").compileFailFmt(state, "for body must be block", .{}),
    };
}

fn compileCondFor(state: *CompilerState, for_expr: *const ast.For) !void {
    const loop_start = state.chunk.code.items.len;
    var exit_jump: ?usize = null;

    var is_infinite = false;
    if (for_expr.expr.* == .literal and std.mem.eql(u8, for_expr.expr.literal.value, "true")) {
        is_infinite = true;
    }

    if (!is_infinite) {
        try expr.compileExpression(state, for_expr.expr);
        exit_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
        try emit.emitOp(state, .OP_POP);
    }

    try scope.beginScope(state);
    const body = try bodyBlock(state, for_expr);
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    var loop = state.loops.pop().?;
    for (loop.continue_jumps.items) |cj| emit.patchJump(state, cj);
    try emit.emitLoop(state, loop_start);

    if (exit_jump) |ej| {
        emit.patchJump(state, ej);
        try emit.emitOp(state, .OP_POP);
    }
    for (loop.break_jumps.items) |bj| emit.patchJump(state, bj);
    loop.break_jumps.deinit(state.allocator);
    loop.continue_jumps.deinit(state.allocator);
}

fn compileRangeFor(state: *CompilerState, for_expr: *const ast.For) !void {
    if (for_expr.expr.* != .binary or !std.mem.eql(u8, for_expr.expr.binary.operator, "..")) {
        return fail(state, "Range loops must have a start and end.");
    }
    const start = for_expr.expr.binary.left;
    const end = for_expr.expr.binary.right;
    if (for_expr.captures.len == 0) return fail(state, "Range loop missing capture");

    try expr.compileExpression(state, start);
    try state.locals.append(state.allocator, .{
        .name = for_expr.captures[0].name,
        .depth = state.scope_depth,
        .is_const = true,
        .type_name = "int",
    });
    const i_index: u8 = @intCast(state.locals.items.len - 1);

    try expr.compileExpression(state, end);
    try state.locals.append(state.allocator, .{ .name = ".range_end", .depth = state.scope_depth, .type_name = "int" });
    const end_index: u8 = @intCast(state.locals.items.len - 1);

    // OP_FOR_PREP i end skip — skip patched after FOR_LOOP
    try emit.emitOp(state, .OP_FOR_PREP);
    try emit.emitByte(state, i_index);
    try emit.emitByte(state, end_index);
    const prep_skip = state.chunk.code.items.len;
    try emit.emitByte(state, 0xff);
    try emit.emitByte(state, 0xff);

    const body_start = state.chunk.code.items.len;
    try scope.beginScope(state);
    const body = try bodyBlock(state, for_expr);
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    var loop = state.loops.pop().?;
    for (loop.continue_jumps.items) |cj| emit.patchJump(state, cj);

    // OP_FOR_LOOP i end back_offset (distance back to body_start from after this insn)
    try emit.emitOp(state, .OP_FOR_LOOP);
    try emit.emitByte(state, i_index);
    try emit.emitByte(state, end_index);
    // offset = (ip after reading operands) - body_start; after emit: len+2 is after short
    const after_op = state.chunk.code.items.len + 2; // after the two offset bytes we're about to write
    const back: usize = after_op - body_start;
    if (back > 0xffff) unreachable;
    try emit.emitByte(state, @intCast((back >> 8) & 0xff));
    try emit.emitByte(state, @intCast(back & 0xff));

    // Patch FOR_PREP skip to land here (after FOR_LOOP)
    const skip = state.chunk.code.items.len - prep_skip - 2;
    if (skip > 0xffff) unreachable;
    state.chunk.code.items[prep_skip] = @intCast((skip >> 8) & 0xff);
    state.chunk.code.items[prep_skip + 1] = @intCast(skip & 0xff);

    for (loop.break_jumps.items) |bj| emit.patchJump(state, bj);
    loop.break_jumps.deinit(state.allocator);
    loop.continue_jumps.deinit(state.allocator);
}

fn compileIterFor(state: *CompilerState, for_expr: *const ast.For) !void {
    const iterable = for_expr.expr;
    try expr.compileExpression(state, iterable);

    const iterable_idx: u8 = @intCast(state.locals.items.len);
    try state.locals.append(state.allocator, .{ .name = ".iterable", .depth = state.scope_depth });

    const i_index: u8 = @intCast(state.locals.items.len);
    try state.locals.append(state.allocator, .{ .name = ".i", .depth = state.scope_depth });
    try emit.emitConstant(state, .{ .i64 = 0 });

    const loop_start = state.chunk.code.items.len;
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "len");
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, iterable_idx);
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try emit.emitOp(state, .OP_LESS);

    const exit_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);

    try scope.beginScope(state);
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, iterable_idx);
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitOp(state, .OP_GET_INDEX);
    if (for_expr.captures.len > 0) {
        try state.locals.append(state.allocator, .{
            .name = for_expr.captures[0].name,
            .depth = state.scope_depth,
        });
    }
    if (for_expr.captures.len > 1) {
        try emit.emitOp(state, .OP_GET_LOCAL);
        try emit.emitByte(state, i_index);
        try state.locals.append(state.allocator, .{
            .name = for_expr.captures[1].name,
            .depth = state.scope_depth,
        });
    }

    const body = try bodyBlock(state, for_expr);
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    var loop = state.loops.pop().?;
    for (loop.continue_jumps.items) |cj| emit.patchJump(state, cj);

    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitConstant(state, .{ .i64 = 1 });
    try emit.emitOp(state, .OP_ADD);
    try emit.emitOp(state, .OP_SET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitOp(state, .OP_POP);

    try emit.emitLoop(state, loop_start);
    emit.patchJump(state, exit_jump);
    try emit.emitOp(state, .OP_POP);
    for (loop.break_jumps.items) |bj| emit.patchJump(state, bj);
    loop.break_jumps.deinit(state.allocator);
    loop.continue_jumps.deinit(state.allocator);
}

fn fail(state: *CompilerState, msg: []const u8) error{CompileError} {
    return @import("../../errors/compile.zig").compileFailFmt(state, "{s}", .{msg});
}
