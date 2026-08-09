const std = @import("std");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");

const VMState = state_mod.VMState;
const Value = state_mod.Value;
const OpCode = @import("../../bytecode/opcode.zig").OpCode;

pub const ArithError = error{ RuntimeError, TypeError, OutOfMemory };

fn fail(msg: []const u8) ArithError {
    @import("std").debug.print("RuntimeError: {s}\n", .{msg});
    return error.RuntimeError;
}

const ArithOp = enum { add, sub, mul, div, mod, pow };

fn asInt(v: Value) ?i32 {
    return switch (v) {
        .int => |n| n,
        .ptr => |p| p,
        .bool => |b| @intFromBool(b),
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

fn asFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |n| n,
        .ptr => |p| @floatFromInt(p),
        .bool => |b| @floatFromInt(@intFromBool(b)),
        else => null,
    };
}

pub fn binArith(vm: *VMState, op: OpCode) ArithError!void {
    const kind: ArithOp = switch (op) {
        .OP_ADD => .add,
        .OP_SUB => .sub,
        .OP_MUL => .mul,
        .OP_DIV => .div,
        .OP_MOD => .mod,
        .OP_POW => .pow,
        else => return fail("Bad arith op"),
    };
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const use_float = a == .float or b == .float;
    if (use_float) {
        const af = asFloat(a) orelse return fail("Operands must be numbers");
        const bf = asFloat(b) orelse return fail("Operands must be numbers");
        const result: f64 = switch (kind) {
            .add => af + bf,
            .sub => af - bf,
            .mul => af * bf,
            .div => if (bf == 0) return fail("Division by zero") else af / bf,
            .mod => if (bf == 0) return fail("Division by zero") else @mod(af, bf),
            .pow => std.math.pow(f64, af, bf),
        };
        try stack.push(vm, .{ .float = result });
        return;
    }
    const ai = asInt(a) orelse return fail("Operands must be numbers");
    const bi = asInt(b) orelse return fail("Operands must be numbers");
    const result: i32 = switch (kind) {
        .add => ai +% bi,
        .sub => ai -% bi,
        .mul => ai *% bi,
        .div => if (bi == 0) return fail("Division by zero") else @divTrunc(ai, bi),
        .mod => if (bi == 0) return fail("Division by zero") else @rem(ai, bi),
        .pow => powi(ai, bi),
    };
    // Preserve pointer-ness when adding offsets to a heap ptr (array bump).
    // Subtraction of two ptrs yields an int distance.
    if (kind == .add and (a == .ptr or b == .ptr)) {
        try stack.push(vm, .{ .ptr = result });
    } else {
        try stack.push(vm, .{ .int = result });
    }
}

fn powi(base: i32, exp: i32) i32 {
    if (exp < 0) return 0;
    var result: i32 = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *%= b;
        b *%= b;
    }
    return result;
}

pub fn negate(vm: *VMState) ArithError!void {
    const a = stack.pop(vm);
    switch (a) {
        .int => |n| try stack.push(vm, .{ .int = -n }),
        .float => |n| try stack.push(vm, .{ .float = -n }),
        else => return fail("Operand must be a number"),
    }
}

pub fn not_(vm: *VMState) ArithError!void {
    const a = stack.pop(vm);
    try stack.push(vm, .{ .bool = !a.isTruthy() });
}
