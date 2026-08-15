const std = @import("std");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const runtime = @import("../../errors/runtime.zig");

const VMState = state_mod.VMState;
const Value = state_mod.Value;
const OpCode = @import("../../bytecode/opcode.zig").OpCode;

pub const ArithError = error{ RuntimeError, TypeError, OutOfMemory };

fn fail(vm: *VMState, msg: []const u8) ArithError {
    return runtime.runtimeFail(vm, msg);
}

const ArithOp = enum { add, sub, mul, div, mod, pow };

fn asInt(v: Value) ?i64 {
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
        else => return fail(vm, "Bad arith op"),
    };
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const use_float = a == .float or b == .float;
    if (use_float) {
        const af = asFloat(a) orelse return fail(vm, "Operands must be numbers");
        const bf = asFloat(b) orelse return fail(vm, "Operands must be numbers");
        const result: f64 = switch (kind) {
            .add => af + bf,
            .sub => af - bf,
            .mul => af * bf,
            .div => if (bf == 0) return fail(vm, "Division by zero") else af / bf,
            .mod => if (bf == 0) return fail(vm, "Division by zero") else @mod(af, bf),
            .pow => std.math.pow(f64, af, bf),
        };
        try stack.push(vm, .{ .float = result });
        return;
    }
    const ai = asInt(a) orelse return fail(vm, "Operands must be numbers");
    const bi = asInt(b) orelse return fail(vm, "Operands must be numbers");
    const result: i64 = switch (kind) {
        .add => ai +% bi,
        .sub => ai -% bi,
        .mul => ai *% bi,
        .div => if (bi == 0) return fail(vm, "Division by zero") else @divTrunc(ai, bi),
        .mod => if (bi == 0) return fail(vm, "Division by zero") else @rem(ai, bi),
        .pow => powi(ai, bi),
    };
    // Preserve pointer-ness when adding offsets to a heap ptr (array bump).
    // Subtraction of two ptrs yields an int distance.
    if (kind == .add and (a == .ptr or b == .ptr)) {
        try stack.push(vm, .{ .ptr = @intCast(result) });
    } else {
        try stack.push(vm, .{ .int = result });
    }
}

pub const I64Op = enum { add, sub, mul };

pub fn binArithI64(vm: *VMState, kind: I64Op) ArithError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const ai = switch (a) {
        .int => |n| n,
        else => return fail(vm, "Operands must be ints"),
    };
    const bi = switch (b) {
        .int => |n| n,
        else => return fail(vm, "Operands must be ints"),
    };
    const result: i64 = switch (kind) {
        .add => ai +% bi,
        .sub => ai -% bi,
        .mul => ai *% bi,
    };
    try stack.push(vm, .{ .int = result });
}

pub fn ltI64(vm: *VMState) ArithError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const ai = switch (a) {
        .int => |n| n,
        else => return fail(vm, "Operands must be ints"),
    };
    const bi = switch (b) {
        .int => |n| n,
        else => return fail(vm, "Operands must be ints"),
    };
    try stack.push(vm, .{ .bool = ai < bi });
}

fn powi(base: i64, exp: i64) i64 {
    if (exp < 0) return 0;
    var result: i64 = 1;
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
        else => return fail(vm, "Operand must be a number"),
    }
}

pub fn not_(vm: *VMState) ArithError!void {
    const a = stack.pop(vm);
    try stack.push(vm, .{ .bool = !a.isTruthy() });
}

const BitOp = enum { band, bor, bxor, shl, shr };

/// Bitwise ops are integer-only (floats rejected).
pub fn binBitwise(vm: *VMState, op: OpCode) ArithError!void {
    const kind: BitOp = switch (op) {
        .OP_BIT_AND => .band,
        .OP_BIT_OR => .bor,
        .OP_BIT_XOR => .bxor,
        .OP_SHL => .shl,
        .OP_SHR => .shr,
        else => return fail(vm, "Bad bitwise op"),
    };
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    if (a == .float or b == .float) return fail(vm, "Bitwise operands must be integers");
    const ai = asInt(a) orelse return fail(vm, "Bitwise operands must be integers");
    const bi = asInt(b) orelse return fail(vm, "Bitwise operands must be integers");
    const result: i64 = switch (kind) {
        .band => ai & bi,
        .bor => ai | bi,
        .bxor => ai ^ bi,
        .shl => blk: {
            if (bi < 0 or bi >= 64) return fail(vm, "Shift amount out of range");
            break :blk ai << @intCast(bi);
        },
        .shr => blk: {
            if (bi < 0 or bi >= 64) return fail(vm, "Shift amount out of range");
            break :blk ai >> @intCast(bi);
        },
    };
    try stack.push(vm, .{ .int = result });
}

pub fn bitNot(vm: *VMState) ArithError!void {
    const a = stack.pop(vm);
    if (a == .float) return fail(vm, "Bitwise operand must be an integer");
    const n = asInt(a) orelse return fail(vm, "Bitwise operand must be an integer");
    try stack.push(vm, .{ .int = ~n });
}
