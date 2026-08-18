//! Native math functions backing `std/math.lls` (mirrors
//! `src/vm/builtins/math.zig`). Int-returning functions return `i64`;
//! float-returning functions return `f64`. `min`/`max` receive a
//! count-prefixed `[N+1 x double]` array (ints widened to f64 by the caller)
//! and compare as f64, exactly like the VM's `minMax`.

const std = @import("std");

// ──────────────────────────────── min/max ─────────────────────────────────

fn minMax(arr: [*]align(8) const u8, find_max: bool) f64 {
    const elems: [*]const f64 = @ptrCast(arr);
    const count: usize = @intCast(@as(i64, @bitCast(elems[~@as(usize, 0)])));
    if (count == 0) return if (find_max) -std.math.inf(f64) else std.math.inf(f64);
    var best = elems[0];
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const n = elems[i];
        if (find_max and n > best) best = n;
        if (!find_max and n < best) best = n;
    }
    return best;
}

export fn __min(arr: [*]align(8) const u8) f64 {
    return minMax(arr, false);
}

export fn __max(arr: [*]align(8) const u8) f64 {
    return minMax(arr, true);
}

// ─────────────────────────────── rounding ─────────────────────────────────

export fn __floor(x: f64) i64 {
    return @intFromFloat(@floor(x));
}

export fn __ceil(x: f64) i64 {
    return @intFromFloat(@ceil(x));
}

export fn __round(x: f64) i64 {
    return @intFromFloat(@round(x));
}

export fn __trunc(x: f64) f64 {
    return std.math.trunc(x);
}

export fn __rint(x: f64) f64 {
    return rint(x);
}

export fn __nearbyint(x: f64) f64 {
    return nearbyint(x);
}

export fn __llrint(x: f64) i64 {
    return llrint(x);
}

export fn __lrint(x: f64) i64 {
    return lrint(x);
}

export fn __llround(x: f64) i64 {
    return llround(x);
}

export fn __lround(x: f64) i64 {
    return lround(x);
}

// ──────────────────────────── powers / roots ──────────────────────────────

export fn __sqrt(x: f64) i64 {
    if (x < 0) return std.math.minInt(i64);
    return @intFromFloat(@sqrt(x));
}

export fn __cbrt(x: f64) f64 {
    return std.math.cbrt(x);
}

export fn __pow(a: f64, b: f64) i64 {
    return @intFromFloat(std.math.pow(f64, a, b));
}

export fn __exp(x: f64) f64 {
    return std.math.exp(x);
}

export fn __exp2(x: f64) f64 {
    return std.math.exp2(x);
}

export fn __expm1(x: f64) f64 {
    return std.math.expm1(x);
}

export fn __log(x: f64) f64 {
    return @log(x);
}

export fn __log10(x: f64) f64 {
    return std.math.log10(x);
}

export fn __log2(x: f64) f64 {
    return std.math.log2(x);
}

export fn __log1p(x: f64) f64 {
    return log1p(x);
}

export fn __logb(x: f64) f64 {
    return logb(x);
}

export fn __hypot(x: f64, y: f64) f64 {
    return hypot(x, y);
}

// ────────────────────────────── trig / hyper ──────────────────────────────

export fn __sin(x: f64) f64 {
    return std.math.sin(x);
}

export fn __cos(x: f64) f64 {
    return std.math.cos(x);
}

export fn __tan(x: f64) f64 {
    return std.math.tan(x);
}

export fn __asin(x: f64) f64 {
    return std.math.asin(x);
}

export fn __acos(x: f64) f64 {
    return std.math.acos(x);
}

export fn __atan(x: f64) f64 {
    return std.math.atan(x);
}

export fn __atan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}

export fn __sinh(x: f64) f64 {
    return std.math.sinh(x);
}

export fn __cosh(x: f64) f64 {
    return std.math.cosh(x);
}

export fn __tanh(x: f64) f64 {
    return std.math.tanh(x);
}

export fn __asinh(x: f64) f64 {
    return std.math.asinh(x);
}

export fn __acosh(x: f64) f64 {
    return std.math.acosh(x);
}

export fn __atanh(x: f64) f64 {
    return std.math.atanh(x);
}

// ──────────────────────────── signs / misc ────────────────────────────────

export fn __sign(x: f64) i64 {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}

export fn __fabs(x: f64) f64 {
    return @abs(x);
}

export fn __copysign(x: f64, y: f64) f64 {
    return copysign(x, y);
}

export fn __fdim(x: f64, y: f64) f64 {
    return fdim(x, y);
}

export fn __fma(x: f64, y: f64, z: f64) f64 {
    return fma(x, y, z);
}

export fn __fmax(x: f64, y: f64) f64 {
    return fmax(x, y);
}

export fn __fmin(x: f64, y: f64) f64 {
    return fmin(x, y);
}

export fn __fmod(x: f64, y: f64) f64 {
    return fmod(x, y);
}

export fn __remainder(x: f64, y: f64) f64 {
    return remainder(x, y);
}

export fn __remquo(x: f64, y: f64) f64 {
    var quo: c_int = 0;
    return remquo(x, y, &quo);
}

export fn __modf(x: f64) f64 {
    var ip: f64 = 0;
    return modf(x, &ip);
}

export fn __frexp(x: f64) f64 {
    var exp: c_int = 0;
    return frexp(x, &exp);
}

export fn __ldexp(x: f64, e: f64) f64 {
    return ldexp(x, @intFromFloat(e));
}

export fn __scalbn(x: f64, e: f64) f64 {
    return scalbn(x, @intFromFloat(e));
}

export fn __scalbln(x: f64, e: f64) f64 {
    return scalbln(x, @intFromFloat(e));
}

export fn __ilogb(x: f64) i64 {
    return ilogb(x);
}

export fn __random() f64 {
    return std.crypto.random.float(f64);
}

export fn __nan(s: [*:0]const u8) f64 {
    _ = s;
    return std.math.nan(f64);
}

export fn __hugeVal() f64 {
    return std.math.inf(f64);
}

export fn __infinity() f64 {
    return std.math.inf(f64);
}

export fn __nanValue() f64 {
    return std.math.nan(f64);
}

export fn __nextafter(x: f64, y: f64) f64 {
    return nextafter(x, y);
}

export fn __nexttoward(x: f64, y: f64) f64 {
    return nexttoward(x, y);
}

export fn __erf(x: f64) f64 {
    return erf(x);
}

export fn __erfc(x: f64) f64 {
    return erfc(x);
}

export fn __lgamma(x: f64) f64 {
    return lgamma(x);
}

export fn __tgamma(x: f64) f64 {
    return tgamma(x);
}

// ──────────────────────────── classification ──────────────────────────────

export fn __fpclassify(x: f64) i64 {
    // Mirror the VM's C FP_* codes: 0=NAN, 1=INF, 2=ZERO, 3=SUBNORMAL, 4=NORMAL.
    if (std.math.isNan(x)) return 0;
    if (std.math.isInf(x)) return 1;
    if (x == 0.0) return 2;
    if (std.math.isNormal(x)) return 4;
    return 3;
}

export fn __isfinite(x: f64) bool {
    return std.math.isFinite(x);
}

export fn __isnan(x: f64) bool {
    return std.math.isNan(x);
}

export fn __isinf(x: f64) bool {
    return std.math.isInf(x);
}

export fn __isnormal(x: f64) bool {
    return std.math.isNormal(x);
}

export fn __signbit(x: f64) bool {
    return std.math.signbit(x);
}

export fn __isgreater(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and a > b;
}

export fn __isgreaterequal(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and a >= b;
}

export fn __isless(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and a < b;
}

export fn __islessequal(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and a <= b;
}

export fn __islessgreater(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and (a < b or a > b);
}

export fn __isunordered(a: f64, b: f64) bool {
    return std.math.isNan(a) or std.math.isNan(b);
}

// ─────────────────────────────── libm externs ─────────────────────────────
// Linked via `-lm` in scripts/emit-run.sh.

extern fn erf(x: f64) f64;
extern fn erfc(x: f64) f64;
extern fn copysign(x: f64, y: f64) f64;
extern fn fdim(x: f64, y: f64) f64;
extern fn fma(x: f64, y: f64, z: f64) f64;
extern fn fmax(x: f64, y: f64) f64;
extern fn fmin(x: f64, y: f64) f64;
extern fn fmod(x: f64, y: f64) f64;
extern fn frexp(x: f64, exp: *c_int) f64;
extern fn hypot(x: f64, y: f64) f64;
extern fn ilogb(x: f64) c_int;
extern fn ldexp(x: f64, exp: c_int) f64;
extern fn lgamma(x: f64) f64;
extern fn log1p(x: f64) f64;
extern fn logb(x: f64) f64;
extern fn modf(x: f64, intpart: *f64) f64;
extern fn nearbyint(x: f64) f64;
extern fn nextafter(x: f64, y: f64) f64;
extern fn nexttoward(x: f64, y: f64) f64;
extern fn remainder(x: f64, y: f64) f64;
extern fn remquo(x: f64, y: f64, quo: *c_int) f64;
extern fn rint(x: f64) f64;
extern fn scalbln(x: f64, exp: c_long) f64;
extern fn scalbn(x: f64, exp: c_int) f64;
extern fn tgamma(x: f64) f64;
extern fn llrint(x: f64) c_longlong;
extern fn llround(x: f64) c_longlong;
extern fn lrint(x: f64) c_long;
extern fn lround(x: f64) c_long;
