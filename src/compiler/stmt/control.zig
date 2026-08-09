const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const stmt = @import("root.zig");
const for_loop = @import("for_loop.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileIf(state: *CompilerState, if_expr: *const ast.If) !void {
    try expr.compileExpression(state, if_expr.condition);
    const then_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);
    try scope.beginScope(state);
    const body = switch (if_expr.body.*) {
        .block => |*b| b,
        else => return fail("if body must be block"),
    };
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    if (if_expr.else_body) |else_body| {
        const else_jump = try emit.emitJump(state, .OP_JUMP);
        emit.patchJump(state, then_jump);
        try emit.emitOp(state, .OP_POP);
        if (else_body.* == .block) {
            try scope.beginScope(state);
            for (else_body.block.statements) |s| try stmt.compileStatement(state, s);
            try scope.endScope(state);
        } else if (else_body.* == .if_expr) {
            try compileIf(state, &else_body.if_expr);
        }
        emit.patchJump(state, else_jump);
    } else {
        const skip_pop = try emit.emitJump(state, .OP_JUMP);
        emit.patchJump(state, then_jump);
        try emit.emitOp(state, .OP_POP);
        emit.patchJump(state, skip_pop);
    }
}

pub fn compileFor(state: *CompilerState, for_expr: *const ast.For) !void {
    try for_loop.compileFor(state, for_expr);
}

pub fn compileBreak(state: *CompilerState, brk: *const ast.Break) !void {
    if (state.loops.items.len == 0) return fail("Cannot break outside of a loop");
    const target = try findLoop(state, brk.label);
    try scope.emitDefersUntil(state, target.scope_depth);
    try scope.emitPopsUntil(state, target.scope_depth);
    const jump = try emit.emitJump(state, .OP_JUMP);
    try target.break_jumps.append(state.allocator, jump);
}

pub fn compileContinue(state: *CompilerState, cont: *const ast.Continue) !void {
    if (state.loops.items.len == 0) return fail("Cannot continue outside of a loop");
    const target = try findLoop(state, cont.label);
    try scope.emitDefersUntil(state, target.scope_depth);
    try scope.emitPopsUntil(state, target.scope_depth);
    const jump = try emit.emitJump(state, .OP_JUMP);
    try target.continue_jumps.append(state.allocator, jump);
}

fn findLoop(state: *CompilerState, label: ?[]const u8) !*state_mod.LoopTracker {
    if (label) |lab| {
        for (state.loops.items) |*loop| {
            if (loop.label) |ll| {
                if (std.mem.eql(u8, ll, lab)) return loop;
            }
        }
        std.debug.print("CompileError: Cannot find loop with label '{s}'\n", .{lab});
        return error.CompileError;
    }
    return &state.loops.items[state.loops.items.len - 1];
}

fn fail(msg: []const u8) error{CompileError} {
    std.debug.print("CompileError: {s}\n", .{msg});
    return error.CompileError;
}
