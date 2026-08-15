const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const decl = @import("decl.zig");
const control = @import("control.zig");
const func = @import("func.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileStatement(state: *CompilerState, node: *ast.Node) anyerror!void {
    const loc = node.loc();
    emit.noteLoc(state, loc.line, loc.column, loc.path);
    try emit.emitLineIfNeeded(state, loc.line, loc.column);
    switch (node.*) {
        .function_decl => |*f| try func.compileFunction(state, f, node),
        .declaration => |*d| try decl.compileDeclaration(state, d),
        .extern_decl => |*e| try decl.compileExtern(state, e),
        .struct_decl => |*s| try decl.compileStruct(state, s),
        .enum_decl => |*e| try decl.compileEnum(state, e),
        .type_decl => |*t| try decl.compileTypeDecl(state, t),
        .block => |*b| try func.compileBlock(state, b),
        .defer_stmt => |*d| try func.compileDefer(state, d),
        .return_expr => |*r| try func.compileReturn(state, r),
        .if_expr => |*i| try control.compileIf(state, i),
        .switch_expr => |*s| try control.compileSwitch(state, s),
        .for_expr => |*f| try control.compileFor(state, f),
        .break_expr => |*b| try control.compileBreak(state, b),
        .continue_expr => |*c| try control.compileContinue(state, c),

        else => {
            try expr.compileExpression(state, node);
            try emit.emitOp(state, .OP_POP);
        },
    }
}

pub const compileFunction = func.compileFunction;
