const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileLiteral(state: *CompilerState, lit: *const ast.Literal) !void {
    try emit.emitLineIfNeeded(state, lit.loc.line);
    switch (lit.literal_type) {
        .@"null" => try emit.emitOp(state, .OP_NULL),
        .boolean => {
            if (std.mem.eql(u8, lit.value, "true")) {
                try emit.emitOp(state, .OP_TRUE);
            } else {
                try emit.emitOp(state, .OP_FALSE);
            }
        },
        .string => try emit.emitString(state, lit.value),
        .number => {
            if (std.mem.indexOfScalar(u8, lit.value, '.')) |_| {
                const f = std.fmt.parseFloat(f64, lit.value) catch return error.CompileError;
                try emit.emitConstant(state, .{ .float = f });
            } else {
                const n = std.fmt.parseInt(i32, lit.value, 10) catch return error.CompileError;
                try emit.emitConstant(state, .{ .int = n });
            }
        },
        .hex => {
            const n = std.fmt.parseInt(i32, lit.value[2..], 16) catch return error.CompileError;
            try emit.emitConstant(state, .{ .int = n });
        },
        .octal => {
            const n = std.fmt.parseInt(i32, lit.value[2..], 8) catch return error.CompileError;
            try emit.emitConstant(state, .{ .int = n });
        },
        .binary => {
            const n = std.fmt.parseInt(i32, lit.value[2..], 2) catch return error.CompileError;
            try emit.emitConstant(state, .{ .int = n });
        },
    }
}
