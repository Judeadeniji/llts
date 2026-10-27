//! Arithmetic, bitwise, and comparison primitives — native counterparts to
//! `src/vm/execute/arith.zig` and `compare.zig`, with VM-exact trap messages
//! and semantics (checked vs wrapping, `@divTrunc`/`@rem`, float `@mod`,
//! wrapping `powi`, 0..63 shifts).
//!
//! Integer ops work on i64 bit patterns: typed ops widen to i128 for the
//! checked/wrap decision, then return the low 64 bits for the emitter to cast
//! to the target native type. Unadorned i64 ops are the `Width.i64` case.

const std = @import("std");
const io = @import("io.zig");
const widths = @import("widths.zig");

const Width = widths.Width;

pub const ArithError = error{RuntimeError};

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

/// Format the overflow diagnostic exactly as the VM does. Public so tests can
/// assert the byte-for-byte message without writing to stderr.
pub fn formatOverflow(buf: []u8, kind: ArithOp, width_name: []const u8) ![]const u8 {
    const wrap: []const u8 = switch (kind) {
        .add => "+%",
        .sub => "-%",
        .mul => "*%",
        else => "",
    };
    // Only `+%`/`-%`/`*%` have a wrapping alternative — division, remainder,
    // and exponentiation have no candidate to suggest.
    return if (wrap.len == 0)
        std.fmt.bufPrint(buf, "Integer overflow: {s} exceeds '{s}'", .{ opVerb(kind), width_name })
    else
        std.fmt.bufPrint(buf, "Integer overflow: {s} exceeds '{s}'; did you mean '{s}'?", .{ opVerb(kind), width_name, wrap });
}

fn overflowFail(kind: ArithOp, width_name: []const u8) ArithError {
    var buf: [192]u8 = undefined;
    const msg = formatOverflow(&buf, kind, width_name) catch return io.failMsg("Integer overflow");
    return io.fail("{s}", .{msg});
}

/// Checked i64 `+`/`-`/`*`; traps on overflow instead of wrapping.
fn checkedI64(kind: ArithOp, a: i64, b: i64) ArithError!i64 {
    const r = switch (kind) {
        .add => @addWithOverflow(a, b),
        .sub => @subWithOverflow(a, b),
        .mul => @mulWithOverflow(a, b),
        else => unreachable,
    };
    if (r[1] != 0) return overflowFail(kind, "i64");
    return r[0];
}

// --- Default-width (i64) integer ops --------------------------------------

pub fn add(a: i64, b: i64) ArithError!i64 {
    return checkedI64(.add, a, b);
}

pub fn addWrap(a: i64, b: i64) i64 {
    return a +% b;
}

pub fn sub(a: i64, b: i64) ArithError!i64 {
    return checkedI64(.sub, a, b);
}

pub fn subWrap(a: i64, b: i64) i64 {
    return a -% b;
}

pub fn mul(a: i64, b: i64) ArithError!i64 {
    return checkedI64(.mul, a, b);
}

pub fn mulWrap(a: i64, b: i64) i64 {
    return a *% b;
}

pub fn div(a: i64, b: i64) ArithError!i64 {
    if (b == 0) return io.failMsg("Division by zero");
    if (a == std.math.minInt(i64) and b == -1) return overflowFail(.div, "i64");
    return @divTrunc(a, b);
}

pub fn rem(a: i64, b: i64) ArithError!i64 {
    if (b == 0) return io.failMsg("Division by zero");
    return @rem(a, b);
}

/// Wrapping integer exponentiation; negative exponents yield 0 (`powi` parity).
pub fn pow(base: i64, exp: i64) i64 {
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

pub fn neg(a: i64) ArithError!i64 {
    if (a == std.math.minInt(i64)) return overflowFail(.sub, "i64");
    return -a;
}

/// Format the shift-range diagnostic exactly as the VM does. Public so tests
/// can assert the message without writing to stderr.
pub fn formatShiftOutOfRange(buf: []u8, b: i64) ![]const u8 {
    return std.fmt.bufPrint(buf, "Shift amount out of range 0..63 (got {d})", .{b});
}

pub fn shl(a: i64, b: i64) ArithError!i64 {
    if (b < 0 or b >= 64) {
        var buf: [64]u8 = undefined;
        const msg = formatShiftOutOfRange(&buf, b) catch return io.failMsg("Shift amount out of range");
        return io.fail("{s}", .{msg});
    }
    return a << @intCast(b);
}

pub fn shr(a: i64, b: i64) ArithError!i64 {
    if (b < 0 or b >= 64) {
        var buf: [64]u8 = undefined;
        const msg = formatShiftOutOfRange(&buf, b) catch return io.failMsg("Shift amount out of range");
        return io.fail("{s}", .{msg});
    }
    return a >> @intCast(b); // arithmetic shift, VM parity
}

pub fn band(a: i64, b: i64) i64 {
    return a & b;
}

pub fn bor(a: i64, b: i64) i64 {
    return a | b;
}

pub fn bxor(a: i64, b: i64) i64 {
    return a ^ b;
}

pub fn bnot(a: i64) i64 {
    return ~a;
}

// --- Width-typed integer ops -----------------------------------------------

pub const TypedKind = enum { add, sub, mul };

/// Width-typed `+`/`-`/`*`. When `checked`, the wide (i128) result must fit
/// the declared width or the op traps; when wrapping, the low bits are kept
/// (two's complement), matching `+%`/`-%`/`*%` / `binArithTyped`.
fn typedArith(kind: TypedKind, width: Width, a: i64, b: i64, checked: bool) ArithError!i64 {
    // VM fast path: i64/isize checked ops use @addWithOverflow directly.
    if (width == .i64 or width == .isize) {
        const op: ArithOp = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
        };
        if (checked) return checkedI64(op, a, b);
        return switch (kind) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
        };
    }
    // Widen to i128 so the true product/sum is representable, then either trap
    // when it leaves the declared range or truncate for wrapping semantics.
    const wide: i128 = switch (kind) {
        .add => @as(i128, a) + @as(i128, b),
        .sub => @as(i128, a) - @as(i128, b),
        .mul => @as(i128, a) * @as(i128, b),
    };
    if (checked and !widths.i128Fits(width, wide)) {
        const op: ArithOp = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
        };
        return overflowFail(op, width.name());
    }
    // Wrapping: keep the low bits, then normalise to the declared width the
    // way the VM's wrapToWidth + read-back does — sign-extend signed widths,
    // zero-extend unsigned ones.
    const low: i64 = @truncate(wide);
    return switch (width.concrete()) {
        .i8 => @as(i64, @as(i8, @truncate(low))),
        .i16 => @as(i64, @as(i16, @truncate(low))),
        .i32 => @as(i64, @as(i32, @truncate(low))),
        .i64, .isize => low,
        .u1 => low & 1,
        .u8 => @as(i64, @as(u8, @truncate(@as(u64, @bitCast(low))))),
        .u16 => @as(i64, @as(u16, @truncate(@as(u64, @bitCast(low))))),
        .u32 => @as(i64, @as(u32, @truncate(@as(u64, @bitCast(low))))),
        .u64, .usize => low, // bit-preserving two's-complement pattern
        .f32, .f64, .fsize => unreachable,
    };
}

pub fn addChecked(width: Width, a: i64, b: i64) ArithError!i64 {
    return typedArith(.add, width, a, b, true);
}

pub fn addWrapped(width: Width, a: i64, b: i64) i64 {
    return typedArith(.add, width, a, b, false) catch unreachable;
}

pub fn subChecked(width: Width, a: i64, b: i64) ArithError!i64 {
    return typedArith(.sub, width, a, b, true);
}

pub fn subWrapped(width: Width, a: i64, b: i64) i64 {
    return typedArith(.sub, width, a, b, false) catch unreachable;
}

pub fn mulChecked(width: Width, a: i64, b: i64) ArithError!i64 {
    return typedArith(.mul, width, a, b, true);
}

pub fn mulWrapped(width: Width, a: i64, b: i64) i64 {
    return typedArith(.mul, width, a, b, false) catch unreachable;
}

/// Typed `<` (`OP_LT_TYPED` parity): exact i64 comparison, width unused for
/// the raw comparison itself.
pub fn ltWidth(width: Width, a: i64, b: i64) bool {
    _ = width;
    return a < b;
}

// --- Floats ----------------------------------------------------------------

/// f64 ops (`binArith` float path): div/mod trap on zero, pow via
/// std.math.pow, mod is `@mod` (floored) not `@rem`.
pub fn addF64(a: f64, b: f64) f64 {
    return a + b;
}

pub fn subF64(a: f64, b: f64) f64 {
    return a - b;
}

pub fn mulF64(a: f64, b: f64) f64 {
    return a * b;
}

pub fn divF64(a: f64, b: f64) ArithError!f64 {
    if (b == 0) return io.failMsg("Division by zero");
    return a / b;
}

pub fn modF64(a: f64, b: f64) ArithError!f64 {
    if (b == 0) return io.failMsg("Division by zero");
    return @mod(a, b);
}

pub fn powF64(a: f64, b: f64) f64 {
    return std.math.pow(f64, a, b);
}

pub fn negF64(a: f64) f64 {
    return -a;
}

/// f32 ops — preserved f32 arithmetic when both sides are f32 (VM parity).
pub fn addF32(a: f32, b: f32) f32 {
    return a + b;
}

pub fn subF32(a: f32, b: f32) f32 {
    return a - b;
}

pub fn mulF32(a: f32, b: f32) f32 {
    return a * b;
}

pub fn divF32(a: f32, b: f32) ArithError!f32 {
    if (b == 0) return io.failMsg("Division by zero");
    return a / b;
}

pub fn modF32(a: f32, b: f32) ArithError!f32 {
    if (b == 0) return io.failMsg("Division by zero");
    return @mod(a, b);
}

pub fn powF32(a: f32, b: f32) f32 {
    return @floatCast(std.math.pow(f64, a, b));
}

pub fn negF32(a: f32) f32 {
    return -a;
}

// --- Comparisons -----------------------------------------------------------

/// Numeric `<`/`<=`/`>`/`>=` on i64 (exact; the VM's untyped path routes
/// through f64 and loses precision above 2^53 — a VM bug the native backend
/// does not inherit).
pub fn ltI64(a: i64, b: i64) bool {
    return a < b;
}

pub fn leI64(a: i64, b: i64) bool {
    return a <= b;
}

pub fn gtI64(a: i64, b: i64) bool {
    return a > b;
}

pub fn geI64(a: i64, b: i64) bool {
    return a >= b;
}

pub fn ltF64(a: f64, b: f64) bool {
    return a < b;
}

pub fn leF64(a: f64, b: f64) bool {
    return a <= b;
}

pub fn gtF64(a: f64, b: f64) bool {
    return a > b;
}

pub fn geF64(a: f64, b: f64) bool {
    return a >= b;
}

pub fn ltF32(a: f32, b: f32) bool {
    return a < b;
}

pub fn leF32(a: f32, b: f32) bool {
    return a <= b;
}

pub fn gtF32(a: f32, b: f32) bool {
    return a > b;
}

pub fn geF32(a: f32, b: f32) bool {
    return a >= b;
}

// --- Equality --------------------------------------------------------------

pub fn eqI64(a: i64, b: i64) bool {
    return a == b;
}

pub fn eqF64(a: f64, b: f64) bool {
    return a == b;
}

pub fn eqBool(a: bool, b: bool) bool {
    return a == b;
}

/// String equality by content (`stringEquals` parity).
pub fn eqStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
