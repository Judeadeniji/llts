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

    switch (for_expr.kind) {
        .condition => try compileCondFor(state, for_expr),
        .range => try compileRangeFor(state, for_expr),
        .iterable => try compileIterFor(state, for_expr),
    }

    try scope.endScope(state);
}

fn bodyBlock(for_expr: *const ast.For) !*const ast.Block {
    return switch (for_expr.body.*) {
        .block => |*b| b,
        else => {
            std.debug.print("CompileError: for body must be block\n", .{});
            return error.CompileError;
        },
    };
}

fn compileCondFor(state: *CompilerState, for_expr: *const ast.For) !void {
    const loop_start = state.chunk.code.items.len;
    var exit_jump: ?usize = null;

    var is_infinite = false;
    if (for_expr.condition) |cond| {
        if (cond.* == .literal and std.mem.eql(u8, cond.literal.value, "true")) {
            is_infinite = true;
        }
    }

    if (!is_infinite) {
        if (for_expr.condition) |cond| {
            try expr.compileExpression(state, cond);
            exit_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
            try emit.emitOp(state, .OP_POP);
        }
    }

    try scope.beginScope(state);
    const body = try bodyBlock(for_expr);
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
    const start = for_expr.range_start orelse return fail("Range loops must have a start and end.");
    const end = for_expr.range_end orelse return fail("Range loops must have a start and end.");
    if (for_expr.captures.len == 0) return fail("Range loop missing capture");

    try expr.compileExpression(state, start);
    try state.locals.append(state.allocator, .{
        .name = for_expr.captures[0].name,
        .depth = state.scope_depth,
        .is_const = true,
    });
    const i_index: u8 = @intCast(state.locals.items.len - 1);

    try expr.compileExpression(state, end);
    try state.locals.append(state.allocator, .{ .name = ".range_end", .depth = state.scope_depth });
    const end_index: u8 = @intCast(state.locals.items.len - 1);

    const loop_start = state.chunk.code.items.len;
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, end_index);
    try emit.emitOp(state, .OP_LESS);

    const exit_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);

    try scope.beginScope(state);
    const body = try bodyBlock(for_expr);
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    var loop = state.loops.pop().?;
    for (loop.continue_jumps.items) |cj| emit.patchJump(state, cj);

    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitConstant(state, .{ .int = 1 });
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

fn compileIterFor(state: *CompilerState, for_expr: *const ast.For) !void {
    const iterable = for_expr.iterable orelse return fail("Iterable for missing iterable");
    try expr.compileExpression(state, iterable);

    const iterable_idx: u8 = @intCast(state.locals.items.len);
    try state.locals.append(state.allocator, .{ .name = ".iterable", .depth = state.scope_depth });

    const i_index: u8 = @intCast(state.locals.items.len);
    try state.locals.append(state.allocator, .{ .name = ".i", .depth = state.scope_depth });
    try emit.emitConstant(state, .{ .int = 0 });

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

    const body = try bodyBlock(for_expr);
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    var loop = state.loops.pop().?;
    for (loop.continue_jumps.items) |cj| emit.patchJump(state, cj);

    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, i_index);
    try emit.emitConstant(state, .{ .int = 1 });
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

fn fail(msg: []const u8) error{CompileError} {
    std.debug.print("CompileError: {s}\n", .{msg});
    return error.CompileError;
}
