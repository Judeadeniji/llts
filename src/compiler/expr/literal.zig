const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");

const CompilerState = state_mod.CompilerState;

fn parseIntWithUnderscores(raw: []const u8, radix: u8) !i64 {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return error.CompileError;
        buf[len] = c;
        len += 1;
    }
    return std.fmt.parseInt(i64, buf[0..len], radix);
}

fn parseFloatWithUnderscores(raw: []const u8) !f64 {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return error.CompileError;
        buf[len] = c;
        len += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..len]);
}

pub fn compileLiteral(state: *CompilerState, lit: *const ast.Literal) !void {
    try emit.emitLineIfNeeded(state, lit.loc.line, lit.loc.column);
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
                const f = parseFloatWithUnderscores(lit.value) catch return error.CompileError;
                try emit.emitConstant(state, .{ .f64 = f });
            } else {
                const n = parseIntWithUnderscores(lit.value, 10) catch return error.CompileError;
                try emit.emitConstant(state, .{ .i64 = n });
            }
        },
        .hex => {
            const n = parseIntWithUnderscores(lit.value[2..], 16) catch return error.CompileError;
            try emit.emitConstant(state, .{ .i64 = n });
        },
        .octal => {
            const n = parseIntWithUnderscores(lit.value[2..], 8) catch return error.CompileError;
            try emit.emitConstant(state, .{ .i64 = n });
        },
        .binary => {
            const n = parseIntWithUnderscores(lit.value[2..], 2) catch return error.CompileError;
            try emit.emitConstant(state, .{ .i64 = n });
        },
    }
}
