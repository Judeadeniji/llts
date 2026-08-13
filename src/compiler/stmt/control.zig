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

/// Value-producing `@if`: every arm must `break <value>`; result left on the stack.
pub fn compileIfValue(state: *CompilerState, if_expr: *const ast.If) !void {
    if (if_expr.else_body == null) return fail("value-producing @if requires @else");
    try beginExprFrame(state, if_expr.label);
    try compileIfValueBody(state, if_expr);
    try finishExprFrame(state);
}

fn compileIfValueBody(state: *CompilerState, if_expr: *const ast.If) !void {
    try expr.compileExpression(state, if_expr.condition);
    const then_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);

    try compileValueArm(state, if_expr.body, "then");

    const end_jump = try emit.emitJump(state, .OP_JUMP);
    emit.patchJump(state, then_jump);
    try emit.emitOp(state, .OP_POP);

    const else_body = if_expr.else_body orelse return fail("value-producing @if requires @else");
    if (else_body.* == .if_expr) {
        try compileIfValueBody(state, &else_body.if_expr);
    } else {
        try compileValueArm(state, else_body, "else");
    }
    emit.patchJump(state, end_jump);
}

pub fn compileSwitch(state: *CompilerState, sw: *const ast.Switch) !void {
    try compileSwitchInner(state, sw, false);
}

pub fn compileSwitchValue(state: *CompilerState, sw: *const ast.Switch) !void {
    if (!hasElseProng(sw)) return fail("value-producing @switch requires @else");
    try beginExprFrame(state, sw.label);
    try compileSwitchInner(state, sw, true);
    try finishExprFrame(state);
}

fn hasElseProng(sw: *const ast.Switch) bool {
    for (sw.prongs) |p| {
        if (p.is_else) return true;
    }
    return false;
}

fn compileSwitchInner(state: *CompilerState, sw: *const ast.Switch, value_mode: bool) !void {
    try scope.beginScope(state);
    try expr.compileExpression(state, sw.condition);
    const scrut_slot = try scope.addLocal(state, "", false);

    var end_jumps: std.ArrayList(usize) = .empty;
    defer end_jumps.deinit(state.allocator);

    for (sw.prongs) |prong| {
        if (prong.is_else) {
            if (value_mode) {
                try compileValueArm(state, prong.body, "switch @else");
            } else {
                try compileStmtArm(state, prong.body);
            }
            const j = try emit.emitJump(state, .OP_JUMP);
            try end_jumps.append(state.allocator, j);
            continue;
        }
        if (prong.patterns.len == 0) return fail("switch prong requires at least one pattern");

        var matched_jumps: std.ArrayList(usize) = .empty;
        defer matched_jumps.deinit(state.allocator);

        for (prong.patterns, 0..) |pat, i| {
            try emit.emitOp(state, .OP_GET_LOCAL);
            try emit.emitByte(state, scrut_slot);
            try expr.compileExpression(state, pat);
            try emit.emitOp(state, .OP_EQUAL);

            if (i + 1 < prong.patterns.len) {
                const miss = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
                const hit = try emit.emitJump(state, .OP_JUMP);
                try matched_jumps.append(state.allocator, hit);
                emit.patchJump(state, miss);
                try emit.emitOp(state, .OP_POP);
            }
        }

        const no_match = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
        for (matched_jumps.items) |mj| emit.patchJump(state, mj);
        try emit.emitOp(state, .OP_POP);

        if (value_mode) {
            try compileValueArm(state, prong.body, "switch prong");
        } else {
            try compileStmtArm(state, prong.body);
        }
        const done = try emit.emitJump(state, .OP_JUMP);
        try end_jumps.append(state.allocator, done);

        emit.patchJump(state, no_match);
        try emit.emitOp(state, .OP_POP);
    }

    for (end_jumps.items) |j| emit.patchJump(state, j);
    try scope.endScope(state);
}

/// Labeled block as a value: `blk: { break :blk v; }`
pub fn compileBlockValue(state: *CompilerState, block: *const ast.Block) !void {
    if (block.label == null) return fail("value-producing block requires a label (e.g. blk: { break :blk value; })");
    try beginExprFrame(state, block.label);
    const jumps_before = state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len;
    try scope.beginScope(state);
    for (block.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);
    if (state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len == jumps_before) {
        return fail("value-producing block must `break` a value");
    }
    try finishExprFrame(state);
}

fn compileStmtArm(state: *CompilerState, body: *ast.Node) !void {
    try scope.beginScope(state);
    switch (body.*) {
        .block => |b| for (b.statements) |s| try stmt.compileStatement(state, s),
        else => try stmt.compileStatement(state, body),
    }
    try scope.endScope(state);
}

fn compileValueArm(state: *CompilerState, body: *ast.Node, arm_name: []const u8) !void {
    if (state.exprs.items.len == 0) return fail("internal: value arm without expr frame");
    const jumps_before = state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len;
    try scope.beginScope(state);
    switch (body.*) {
        .block => |b| for (b.statements) |s| try stmt.compileStatement(state, s),
        else => try stmt.compileStatement(state, body),
    }
    try scope.endScope(state);
    if (state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len == jumps_before) {
        std.debug.print("CompileError: {s} arm of value expression must `break` a value\n", .{arm_name});
        return error.CompileError;
    }
}

pub fn compileFor(state: *CompilerState, for_expr: *const ast.For) !void {
    try for_loop.compileFor(state, for_expr);
}

pub fn compileBreak(state: *CompilerState, brk: *const ast.Break) !void {
    if (brk.value) |val| {
        const target = try findExpr(state, brk.label);
        try expr.compileExpression(state, val);
        try emit.emitOp(state, .OP_SET_LOCAL);
        try emit.emitByte(state, target.result_slot);
        try emit.emitOp(state, .OP_POP);
        try scope.emitDefersUntil(state, target.scope_depth, .normal);
        try scope.emitPopsUntil(state, target.scope_depth);
        const jump = try emit.emitJump(state, .OP_JUMP);
        try target.break_jumps.append(state.allocator, jump);
        return;
    }

    if (brk.label) |lab| {
        if (findExprLabel(state, lab)) |target| {
            _ = target;
            return fail("break to a value expression requires a value (break :label value;)");
        }
    }

    if (state.loops.items.len == 0) return fail("Cannot break outside of a loop");
    const target = try findLoop(state, brk.label);
    try scope.emitDefersUntil(state, target.scope_depth, .normal);
    try scope.emitPopsUntil(state, target.scope_depth);
    const jump = try emit.emitJump(state, .OP_JUMP);
    try target.break_jumps.append(state.allocator, jump);
}

pub fn compileContinue(state: *CompilerState, cont: *const ast.Continue) !void {
    if (state.loops.items.len == 0) return fail("Cannot continue outside of a loop");
    const target = try findLoop(state, cont.label);
    try scope.emitDefersUntil(state, target.scope_depth, .normal);
    try scope.emitPopsUntil(state, target.scope_depth);
    const jump = try emit.emitJump(state, .OP_JUMP);
    try target.continue_jumps.append(state.allocator, jump);
}

fn beginExprFrame(state: *CompilerState, label: ?[]const u8) !void {
    try scope.beginScope(state);
    try emit.emitOp(state, .OP_NULL);
    const slot = try scope.addLocal(state, "", false);
    try state.exprs.append(state.allocator, .{
        .scope_depth = state.scope_depth,
        .result_slot = slot,
        .label = label,
        .break_jumps = .empty,
    });
}

fn finishExprFrame(state: *CompilerState) !void {
    if (state.exprs.items.len == 0) return fail("internal: finishExprFrame with empty exprs");
    var tracker = state.exprs.pop().?;
    for (tracker.break_jumps.items) |j| emit.patchJump(state, j);
    tracker.break_jumps.deinit(state.allocator);

    // Leave the result value on the stack; drop only the compiler local entry.
    if (state.locals.items.len == 0 or state.locals.items[state.locals.items.len - 1].depth != state.scope_depth) {
        return fail("internal: expr result local missing");
    }
    _ = state.locals.pop();

    if (state.defer_stacks.fetchRemove(state.scope_depth)) |kv| {
        var list = kv.value;
        // Expression frames should not carry defers; run any that slipped in.
        if (list.items.len > 0) {
            var i: isize = @intCast(list.items.len);
            i -= 1;
            while (i >= 0) : (i -= 1) {
                try stmt.compileStatement(state, list.items[@intCast(i)].body);
            }
        }
        list.deinit(state.allocator);
    }
    state.scope_depth -= 1;
}

fn findExpr(state: *CompilerState, label: ?[]const u8) !*state_mod.ExprTracker {
    if (label) |lab| {
        if (findExprLabel(state, lab)) |t| return t;
        std.debug.print("CompileError: Cannot find value expression with label '{s}'\n", .{lab});
        return error.CompileError;
    }
    if (state.exprs.items.len == 0) {
        return fail("break with value requires a value-producing @if, @switch, or labeled block");
    }
    return &state.exprs.items[state.exprs.items.len - 1];
}

fn findExprLabel(state: *CompilerState, lab: []const u8) ?*state_mod.ExprTracker {
    var i: isize = @intCast(state.exprs.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const ex = &state.exprs.items[@intCast(i)];
        if (ex.label) |ll| {
            if (std.mem.eql(u8, ll, lab)) return ex;
        }
    }
    return null;
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
