const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const stmt = @import("root.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileBlock(state: *CompilerState, block: *const ast.Block) !void {
    try scope.beginScope(state);
    for (block.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);
}

pub fn compileDefer(state: *CompilerState, def: *const ast.Defer) !void {
    try scope.pushDefer(state, def.body);
}

pub fn compileReturn(state: *CompilerState, ret: *const ast.Return) !void {
    if (ret.return_value) |v| {
        try expr.compileExpression(state, v);
    } else {
        try emit.emitOp(state, .OP_NULL);
    }
    try scope.emitFunctionExitDefers(state);
    if (state.inline_return_jumps.items.len > 0) {
        const patch = try emit.emitJump(state, .OP_JUMP);
        const top = &state.inline_return_jumps.items[state.inline_return_jumps.items.len - 1];
        try top.append(state.allocator, patch);
    } else {
        try emit.emitOp(state, .OP_RETURN);
    }
}

pub fn compileFunction(state: *CompilerState, node: *ast.FunctionDecl, ast_node: *ast.Node) !void {
    _ = ast_node;
    const outer_locals = state.locals;
    const outer_depth = state.scope_depth;
    const outer_defers = state.defer_stacks;

    state.locals = .empty;
    state.scope_depth = 0;
    state.defer_stacks = std.AutoHashMap(i32, std.ArrayList(*ast.Node)).init(state.allocator);

    try scope.beginScope(state);

    var method_struct: ?[]const u8 = null;
    if (std.mem.lastIndexOf(u8, node.name, "::")) |idx| {
        method_struct = node.name[0..idx];
    }

    const params = switch (node.params.*) {
        .params => |*p| p,
        else => return fail("function params malformed"),
    };

    if (params.is_variadic) {
        try emit.emitOp(state, .OP_PACK_REST);
        try emit.emitByte(state, @intCast(if (params.params.len == 0) 0 else params.params.len - 1));
    }

    for (params.params) |p| {
        try pushParam(state, p, method_struct);
    }

    const body = switch (node.body.*) {
        .block => |*b| b,
        else => return fail("function body must be a block"),
    };
    for (body.statements) |s| try stmt.compileStatement(state, s);

    try scope.emitFunctionExitDefers(state);
    try emit.emitOp(state, .OP_NULL);
    try emit.emitOp(state, .OP_RETURN);

    // discard function-local state
    state.locals.deinit(state.allocator);
    var dit = state.defer_stacks.iterator();
    while (dit.next()) |e| e.value_ptr.deinit(state.allocator);
    state.defer_stacks.deinit();

    state.locals = outer_locals;
    state.scope_depth = outer_depth;
    state.defer_stacks = outer_defers;
}

fn pushParam(state: *CompilerState, p: *ast.Node, method_struct: ?[]const u8) !void {
    switch (p.*) {
        .declaration => |d| {
            var p_type: ?[]const u8 = null;
            if (std.mem.eql(u8, d.name, "self")) p_type = method_struct;
            if (d.type_annotation) |ta| {
                if (ta.* == .primary) p_type = ta.primary.name;
            }
            try state.locals.append(state.allocator, .{
                .name = d.name,
                .depth = state.scope_depth,
                .type_name = p_type,
            });
        },
        .primary => |prim| {
            var p_type: ?[]const u8 = null;
            if (prim.kind == .identifier and std.mem.eql(u8, prim.name, "self")) {
                p_type = method_struct;
            }
            try state.locals.append(state.allocator, .{
                .name = prim.name,
                .depth = state.scope_depth,
                .type_name = p_type,
            });
        },
        else => {},
    }
}

fn fail(msg: []const u8) error{CompileError} {
    std.debug.print("CompileError: {s}\n", .{msg});
    return error.CompileError;
}
