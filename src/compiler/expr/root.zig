const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const literal = @import("literal.zig");
const binary = @import("binary.zig");
const assign = @import("assign.zig");
const call = @import("call.zig");
const aggregate = @import("aggregate.zig");
const path = @import("path.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileExpression(state: *CompilerState, node: *ast.Node) anyerror!void {
    switch (node.*) {
        .literal => |*l| try literal.compileLiteral(state, l),
        .primary => |*p| try compilePrimary(state, p, node),
        .binary => |*b| try binary.compileBinary(state, b),
        .unary => |*u| try binary.compileUnary(state, u),
        .assignment => |*a| try assign.compileAssignment(state, a),
        .call => |*c| try call.compileCall(state, c, node),
        .member => |*m| try aggregate.compileMember(state, m, node),
        .index => |*i| try aggregate.compileIndex(state, i),
        .array_literal => |*a| try aggregate.compileArray(state, a),
        .struct_init => |*s| try aggregate.compileStructInit(state, s),
        .try_expr => |*t| try aggregate.compileTry(state, t),
        .error_expr => |*e| try aggregate.compileError(state, e),
        else => {},
    }
}

fn compilePrimary(state: *CompilerState, prim: *const ast.Primary, node: *ast.Node) !void {
    if (try path.tryResolveStaticPath(state, node)) |static_path| {
        if (state.functions.contains(static_path)) {
            try emit.emitNameGet(state, .OP_GET_FUNCTION, static_path);
        } else if (std.mem.endsWith(u8, static_path, ".lls")) {
            try emit.emitNameGet(state, .OP_GET_MODULE, static_path);
        } else {
            try emit.emitNameGet(state, .OP_GET_GLOBAL, static_path);
        }
        return;
    }
    if (prim.kind != .identifier and prim.kind != .register) return;
    if (state.functions.contains(prim.name) or state.chunk.functions.contains(prim.name)) {
        try emit.emitNameGet(state, .OP_GET_FUNCTION, prim.name);
        return;
    }
    try scope.resolveVariable(state, prim.name);
}
