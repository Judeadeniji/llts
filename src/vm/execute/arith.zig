const std = @import("std");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const runtime = @import("../../errors/runtime.zig");
const widths = @import("../../compiler/widths.zig");
const heap = @import("heap.zig");
const VMState = state_mod.VMState;
const Value = state_mod.Value;
const OpCode = @import("../../bytecode/opcode.zig").OpCode;

pub const ArithError = error{ RuntimeError, TypeError, OutOfMemory };

fn fail(vm: *VMState, msg: []const u8) ArithError {
    return runtime.runtimeFail(vm, msg);
}

const ArithOp = enum { add, sub, mul, div, mod, pow };

/// Human-readable verb for an arithmetic op, used in overflow diagnostics.
fn opVerb(kind: ArithOp) []const u8 {
    return switch (kind) {
        .add => "addition",
        .sub => "subtraction",
        .mul => "multiplication",
        .div => "division",
        .mod => "remainder",
        .pow => "exponentiation",
    };
}

/// Report a detected integer overflow as a deterministic runtime trap.
/// Plain `+`/`-`/`*` are checked; `+%`/`-%`/`*%` and `**` wrap instead.
fn overflowFail(vm: *VMState, kind: ArithOp, width_name: []const u8) ArithError {
    var buf: [192]u8 = undefined;
    const wrap: []const u8 = switch (kind) {
        .add => "+%",
        .sub => "-%",
        .mul => "*%",
        else => "",
    };
    const msg = std.fmt.bufPrint(
        &buf,
        "integer overflow: {s} exceeds '{s}'; use '{s}' if wraparound is intended",
        .{ opVerb(kind), width_name, wrap },
    ) catch "integer overflow";
    return fail(vm, msg);
}

/// Checked i64 `+`/`-`/`*`; traps on overflow instead of wrapping.
fn checkedI64(vm: *VMState, kind: ArithOp, a: i64, b: i64) ArithError!i64 {
    const r = switch (kind) {
        .add => @addWithOverflow(a, b),
        .sub => @subWithOverflow(a, b),
        .mul => @mulWithOverflow(a, b),
        else => unreachable,
    };
    if (r[1] != 0) return overflowFail(vm, kind, "i64");
    return r[0];
}

fn asInt(v: Value) ?i64 {
    return widths.valueAsI64(v);
}

fn asFloat(v: Value) ?f64 {
    return widths.valueAsF64(v);
}

/// `checked` selects trapping (`+`,`-`,`*`) versus wrapping (`+%`,`-%`,`*%`)
/// semantics for integer add/sub/mul. Division/modulo always trap on zero and
/// on the `minInt / -1` overflow; `**` always wraps.
pub fn binArith(vm: *VMState, op: OpCode, checked: bool) ArithError!void {
    const kind: ArithOp = switch (op) {
        .OP_ADD => .add,
        .OP_SUB => .sub,
        .OP_MUL => .mul,
        .OP_DIV => .div,
        .OP_MOD => .mod,
        .OP_POW => .pow,
        else => return fail(vm, "Bad arith op"),
    };
    if (vm.sp >= 2) {
        const a_val = vm.stack_buf[vm.sp - 2];
        const b_val = vm.stack_buf[vm.sp - 1];
        if (a_val == .i64 and b_val == .i64) {
            const ai = a_val.i64;
            const bi = b_val.i64;
            if (bi == 0 and (kind == .div or kind == .mod)) return fail(vm, "Division by zero");
            if (kind == .div and ai == std.math.minInt(i64) and bi == -1)
                return overflowFail(vm, .div, "i64");
            const result: i64 = switch (kind) {
                .add => if (checked) try checkedI64(vm, .add, ai, bi) else ai +% bi,
                .sub => if (checked) try checkedI64(vm, .sub, ai, bi) else ai -% bi,
                .mul => if (checked) try checkedI64(vm, .mul, ai, bi) else ai *% bi,
                .div => @divTrunc(ai, bi),
                .mod => @rem(ai, bi),
                .pow => powi(ai, bi),
            };
            vm.sp -= 1;
            vm.stack_buf[vm.sp - 1] = .{ .i64 = result };
            return;
        }
    }
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    if (kind == .add and (a == .slice or a == .name or a == .bytes or b == .slice or b == .name or b == .bytes)) {
        try stack.push(vm, a);
        try stack.push(vm, b);
        heap.stringAdd(vm) catch |err| switch (err) {
            error.OutOfMemory, error.NoSpaceLeft => return error.OutOfMemory,
            else => return fail(vm, "String concatenation failed"),
        };
        return;
    }
    // Preserve f32 when both sides are f32; otherwise float math is f64.
    if (a == .f32 and b == .f32) {
        const af = a.f32;
        const bf = b.f32;
        const result: f32 = switch (kind) {
            .add => af + bf,
            .sub => af - bf,
            .mul => af * bf,
            .div => if (bf == 0) return fail(vm, "Division by zero") else af / bf,
            .mod => if (bf == 0) return fail(vm, "Division by zero") else @mod(af, bf),
            .pow => @floatCast(std.math.pow(f64, af, bf)),
        };
        try stack.push(vm, .{ .f32 = result });
        return;
    }
    const use_float = a == .f64 or b == .f64 or a == .f32 or b == .f32;
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
        try stack.push(vm, .{ .f64 = result });
        return;
    }
    const ai = asInt(a) orelse return fail(vm, "Operands must be numbers");
    const bi = asInt(b) orelse return fail(vm, "Operands must be numbers");
    const is_ptr = (kind == .add and (a == .ptr or b == .ptr)) or
        (kind == .sub and a == .ptr and b == .ptr);
    const result: i64 = switch (kind) {
        .add => if (checked and !is_ptr) try checkedI64(vm, .add, ai, bi) else ai +% bi,
        .sub => if (checked and !is_ptr) try checkedI64(vm, .sub, ai, bi) else ai -% bi,
        .mul => if (checked) try checkedI64(vm, .mul, ai, bi) else ai *% bi,
        .div => if (bi == 0)
            return fail(vm, "Division by zero")
        else if (ai == std.math.minInt(i64) and bi == -1)
            return overflowFail(vm, .div, "i64")
        else
            @divTrunc(ai, bi),
        .mod => if (bi == 0) return fail(vm, "Division by zero") else @rem(ai, bi),
        .pow => powi(ai, bi),
    };
    // Preserve pointer-ness when adding offsets to a heap ptr (array bump).
    // Subtraction of two ptrs yields an int distance.
    if (kind == .add and (a == .ptr or b == .ptr)) {
        try stack.push(vm, .{ .ptr = @intCast(result) });
    } else {
        try stack.push(vm, .{ .i64 = result });
    }
}

pub const TypedOp = enum { add, sub, mul };

/// Width-typed `+`/`-`/`*`. When `checked`, the *wide* (i128) result must fit
/// the declared width or the VM traps; when wrapping, the low bits are kept
/// (two's complement), matching `+%`/`-%`/`*%`.
pub inline fn binArithTyped(vm: *VMState, kind: TypedOp, width_byte: u8, checked: bool) ArithError!void {
    const width: widths.Width = @enumFromInt(width_byte);
    if (vm.sp >= 2) {
        const a_val = vm.stack_buf[vm.sp - 2];
        const b_val = vm.stack_buf[vm.sp - 1];
        if (a_val == .i64 and b_val == .i64 and (width == .i64 or width == .isize)) {
            const ai = a_val.i64;
            const bi = b_val.i64;
            const result: i64 = switch (kind) {
                .add => if (checked) try checkedI64(vm, .add, ai, bi) else ai +% bi,
                .sub => if (checked) try checkedI64(vm, .sub, ai, bi) else ai -% bi,
                .mul => if (checked) try checkedI64(vm, .mul, ai, bi) else ai *% bi,
            };
            vm.sp -= 1;
            vm.stack_buf[vm.sp - 1] = .{ .i64 = result };
            return;
        }
    }
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const bi = widths.valueAsI64(b) orelse return fail(vm, "Operands must be ints");
    const ai = widths.valueAsI64(a) orelse return fail(vm, "Operands must be ints");
    // Widen to i128 so the true product/sum is representable, then either trap
    // when it leaves the declared range or truncate for wrapping semantics.
    const wide: i128 = switch (kind) {
        .add => @as(i128, ai) + @as(i128, bi),
        .sub => @as(i128, ai) - @as(i128, bi),
        .mul => @as(i128, ai) * @as(i128, bi),
    };
    if (checked and !widths.i128Fits(width, wide)) {
        const kind_op: ArithOp = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
        };
        return overflowFail(vm, kind_op, width.name());
    }
    const result: i64 = @truncate(wide);
    try stack.push(vm, widths.wrapToWidth(result, width));
}

pub fn ltTyped(vm: *VMState, width_byte: u8) ArithError!void {
    _ = width_byte; // The width helps with semantic intent but not the raw comparison since values are extended
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const bi = widths.valueAsI64(b) orelse return fail(vm, "Operands must be ints");
    const ai = widths.valueAsI64(a) orelse return fail(vm, "Operands must be ints");
    try stack.push(vm, .{ .u1 = if (ai < bi) 1 else 0 });
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
        .i64 => |n| {
            if (n == std.math.minInt(i64)) return overflowFail(vm, .sub, "i64");
            try stack.push(vm, .{ .i64 = -n });
        },
        .u8 => |n| try stack.push(vm, .{ .i64 = -@as(i64, n) }),
        .f32 => |n| try stack.push(vm, .{ .f32 = -n }),
        .f64 => |n| try stack.push(vm, .{ .f64 = -n }),
        else => return fail(vm, "Operand must be a number"),
    }
}

pub fn not_(vm: *VMState) ArithError!void {
    const a = stack.pop(vm);
    try stack.push(vm, Value.fromBool(!a.isTruthy()));
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
    if (a == .f64 or b == .f64) return fail(vm, "Bitwise operands must be integers");
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
    try stack.push(vm, .{ .i64 = result });
}

pub fn bitNot(vm: *VMState) ArithError!void {
    const a = stack.pop(vm);
    if (a == .f64) return fail(vm, "Bitwise operand must be an integer");
    const n = asInt(a) orelse return fail(vm, "Bitwise operand must be an integer");
    try stack.push(vm, .{ .i64 = ~n });
}
