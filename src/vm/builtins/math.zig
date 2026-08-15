const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");
const c = @cImport({ @cInclude("math.h"); });

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var floor_n: NativeFunction = undefined;
var ceil_n: NativeFunction = undefined;
var round_n: NativeFunction = undefined;
var sqrt_n: NativeFunction = undefined;
var min_n: NativeFunction = undefined;
var max_n: NativeFunction = undefined;
var pow_n: NativeFunction = undefined;

var random_n: NativeFunction = undefined;
var sin_n: NativeFunction = undefined;
var cos_n: NativeFunction = undefined;
var tan_n: NativeFunction = undefined;
var asin_n: NativeFunction = undefined;
var acos_n: NativeFunction = undefined;
var atan_n: NativeFunction = undefined;
var atan2_n: NativeFunction = undefined;
var log_n: NativeFunction = undefined;
var log10_n: NativeFunction = undefined;
var log2_n: NativeFunction = undefined;
var exp_n: NativeFunction = undefined;
var cbrt_n: NativeFunction = undefined;
var trunc_n: NativeFunction = undefined;
var sign_n: NativeFunction = undefined;

fn asFloat(v: Value) !f64 {
    return switch (v) {
        .i64 => |n| @floatFromInt(n),
        .u8 => |n| @floatFromInt(n),
        .f32 => |n| n,
        .f64 => |n| n,
        .ptr => |p| @floatFromInt(p),
        .u1 => |b| @floatFromInt(b),
        else => error.TypeError,
    };
}

fn floorFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .i64 = @intFromFloat(@floor(try asFloat(args[0]))) };
}

fn ceilFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .i64 = @intFromFloat(@ceil(try asFloat(args[0]))) };
}

fn roundFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .i64 = @intFromFloat(@round(try asFloat(args[0]))) };
}

fn sqrtFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const val = try util.asInt(args[0]);
    if (val < 0) {
        return try util.makeError(vm, "DomainError");
    }
    return .{ .i64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(val)))) };
}

fn minMax(vm: *VMState, args: []Value, find_max: bool) !Value {
    if (args.len < 1) return error.ArityError;

    const get = struct {
        fn elem(v: *VMState, base: Value, i: u32) !f64 {
            const el = switch (base) {
                .array => |a| v.arrayElemConst(a, i),
                .ptr => |p| v.slot(p + @as(i32, @intCast(i))).*,
                else => return error.TypeError,
            };
            return switch (el) {
                .f64 => |f| f,
                .i64 => |n| @floatFromInt(n),
                else => error.TypeError,
            };
        }
        fn lenOf(v: *VMState, base: Value) !u32 {
            return switch (base) {
                .array => |a| a.count,
                .ptr => |p| @intCast(v.slot(p - 1).*.i64),
                else => error.TypeError,
            };
        }
    };

    const base = args[0];
    const len = try get.lenOf(vm, base);
    if (len == 0) return .{ .f64 = std.math.inf(f64) * (if (find_max) @as(f64, -1) else @as(f64, 1)) };
    var best = try get.elem(vm, base, 0);
    var i: u32 = 1;
    while (i < len) : (i += 1) {
        const n = try get.elem(vm, base, i);
        if (find_max and n > best) best = n;
        if (!find_max and n < best) best = n;
    }
    return .{ .f64 = best };
}

fn minFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    return try minMax(vm, args, false);
}

fn maxFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    return try minMax(vm, args, true);
}

fn powFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return .{ .i64 = @intFromFloat(std.math.pow(f64, a, b)) };
}

fn randomFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const r = std.crypto.random.float(f64);
    return .{ .f64 = r };
}

fn sinFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.sin(try asFloat(args[0])) };
}

fn cosFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.cos(try asFloat(args[0])) };
}

fn tanFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.tan(try asFloat(args[0])) };
}

fn asinFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.asin(try asFloat(args[0])) };
}

fn acosFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.acos(try asFloat(args[0])) };
}

fn atanFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.atan(try asFloat(args[0])) };
}

fn atan2Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    return .{ .f64 = std.math.atan2(try asFloat(args[0]), try asFloat(args[1])) };
}

fn logFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = @log(try asFloat(args[0])) };
}

fn log10Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.log10(try asFloat(args[0])) };
}

fn log2Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.log2(try asFloat(args[0])) };
}

fn expFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.exp(try asFloat(args[0])) };
}

fn cbrtFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.cbrt(try asFloat(args[0])) };
}

fn truncFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .f64 = std.math.trunc(try asFloat(args[0])) };
}

fn signFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const v = try asFloat(args[0]);
    if (v > 0) return .{ .i64 = 1 };
    if (v < 0) return .{ .i64 = -1 };
    return .{ .i64 = 0 };
}

var acosh_n: NativeFunction = undefined;
var asinh_n: NativeFunction = undefined;
var atanh_n: NativeFunction = undefined;
var copysign_n: NativeFunction = undefined;
var cosh_n: NativeFunction = undefined;
var erf_n: NativeFunction = undefined;
var erfc_n: NativeFunction = undefined;
var exp2_n: NativeFunction = undefined;
var expm1_n: NativeFunction = undefined;
var fabs_n: NativeFunction = undefined;
var fdim_n: NativeFunction = undefined;
var fma_n: NativeFunction = undefined;
var fmax_n: NativeFunction = undefined;
var fmin_n: NativeFunction = undefined;
var fmod_n: NativeFunction = undefined;
var frexp_n: NativeFunction = undefined;
var hypot_n: NativeFunction = undefined;
var ilogb_n: NativeFunction = undefined;
var ldexp_n: NativeFunction = undefined;
var lgamma_n: NativeFunction = undefined;
var llrint_n: NativeFunction = undefined;
var llround_n: NativeFunction = undefined;
var log1p_n: NativeFunction = undefined;
var logb_n: NativeFunction = undefined;
var lrint_n: NativeFunction = undefined;
var lround_n: NativeFunction = undefined;
var modf_n: NativeFunction = undefined;
var nan_n: NativeFunction = undefined;
var nearbyint_n: NativeFunction = undefined;
var nextafter_n: NativeFunction = undefined;
var nexttoward_n: NativeFunction = undefined;
var remainder_n: NativeFunction = undefined;
var remquo_n: NativeFunction = undefined;
var rint_n: NativeFunction = undefined;
var scalbln_n: NativeFunction = undefined;
var scalbn_n: NativeFunction = undefined;
var sinh_n: NativeFunction = undefined;
var tanh_n: NativeFunction = undefined;
var tgamma_n: NativeFunction = undefined;
var fpclassify_n: NativeFunction = undefined;
var isfinite_n: NativeFunction = undefined;
var isgreater_n: NativeFunction = undefined;
var isgreaterequal_n: NativeFunction = undefined;
var isinf_n: NativeFunction = undefined;
var isless_n: NativeFunction = undefined;
var islessequal_n: NativeFunction = undefined;
var islessgreater_n: NativeFunction = undefined;
var isnan_n: NativeFunction = undefined;
var isnormal_n: NativeFunction = undefined;
var isunordered_n: NativeFunction = undefined;
var signbit_n: NativeFunction = undefined;
var huge_val_n: NativeFunction = undefined;
var infinity_n: NativeFunction = undefined;
var nan_value_n: NativeFunction = undefined;

fn acoshFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.acosh(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn asinhFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.asinh(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn atanhFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.atanh(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn copysignFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.copysign(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn coshFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.cosh(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn erfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.erf(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn erfcFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.erfc(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn exp2Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.exp2(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn expm1Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.expm1(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn fabsFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.fabs(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn fdimFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.fdim(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn fmaFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 3) return error.ArityError;
    const res = c.fma(try asFloat(args[0]), try asFloat(args[1]), try asFloat(args[2]));
    return .{ .f64 = @floatCast(res) };
}

fn fmaxFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.fmax(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn fminFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.fmin(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn fmodFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.fmod(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn frexpFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    var exp: c_int = 0;
    const res = c.frexp(try asFloat(args[0]), &exp);
    return .{ .f64 = res };
}

fn hypotFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.hypot(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn ilogbFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.ilogb(try asFloat(args[0]));
    return .{ .i64 = @intCast(res) };
}

fn ldexpFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const exp: c_int = @intFromFloat(try asFloat(args[1]));
    const res = c.ldexp(try asFloat(args[0]), exp);
    return .{ .f64 = @floatCast(res) };
}

fn lgammaFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.lgamma(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn llrintFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.llrint(try asFloat(args[0]));
    return .{ .i64 = @intCast(res) };
}

fn llroundFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.llround(try asFloat(args[0]));
    return .{ .i64 = @intCast(res) };
}

fn log1pFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.log1p(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn logbFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.logb(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn lrintFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.lrint(try asFloat(args[0]));
    return .{ .i64 = @intCast(res) };
}

fn lroundFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.lround(try asFloat(args[0]));
    return .{ .i64 = @intCast(res) };
}

fn modfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    var iptr: f64 = 0;
    const res = c.modf(try asFloat(args[0]), &iptr);
    return .{ .f64 = res };
}

fn nanFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .f64 = std.math.nan(f64) };
}

fn hugeValFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .f64 = std.math.inf(f64) };
}

fn infinityFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .f64 = std.math.inf(f64) };
}

fn nanValueFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .f64 = std.math.nan(f64) };
}

fn nearbyintFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.nearbyint(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn nextafterFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.nextafter(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn nexttowardFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.nexttoward(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn remainderFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const res = c.remainder(try asFloat(args[0]), try asFloat(args[1]));
    return .{ .f64 = @floatCast(res) };
}

fn remquoFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    var quo: c_int = 0;
    const res = c.remquo(try asFloat(args[0]), try asFloat(args[1]), &quo);
    return .{ .f64 = res };
}

fn rintFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.rint(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn scalblnFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const n: c_long = @intFromFloat(try asFloat(args[1]));
    const res = c.scalbln(try asFloat(args[0]), n);
    return .{ .f64 = @floatCast(res) };
}

fn scalbnFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const n: c_int = @intFromFloat(try asFloat(args[1]));
    const res = c.scalbn(try asFloat(args[0]), n);
    return .{ .f64 = @floatCast(res) };
}

fn sinhFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.sinh(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn tanhFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.tanh(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn tgammaFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const res = c.tgamma(try asFloat(args[0]));
    return .{ .f64 = @floatCast(res) };
}

fn fpclassifyFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const x = try asFloat(args[0]);
    // Mirror C FP_* codes without relying on math.h macros (untranslatable via @cImport).
    const res: i32 = if (std.math.isNan(x))
        0 // FP_NAN
    else if (std.math.isInf(x))
        1 // FP_INFINITE
    else if (x == 0.0)
        2 // FP_ZERO
    else if (std.math.isNormal(x))
        4 // FP_NORMAL
    else
        3; // FP_SUBNORMAL
    return .{ .i64 = res };
}

fn isfiniteFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const x = try asFloat(args[0]);
    return Value.fromBool(!std.math.isNan(x) and !std.math.isInf(x) );
}

fn isgreaterFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return Value.fromBool(!std.math.isNan(a) and !std.math.isNan(b) and a > b );
}

fn isgreaterequalFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return Value.fromBool(!std.math.isNan(a) and !std.math.isNan(b) and a >= b );
}

fn isinfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return Value.fromBool(std.math.isInf(try asFloat(args[0])) );
}

fn islessFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return Value.fromBool(!std.math.isNan(a) and !std.math.isNan(b) and a < b );
}

fn islessequalFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return Value.fromBool(!std.math.isNan(a) and !std.math.isNan(b) and a <= b );
}

fn islessgreaterFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return Value.fromBool(!std.math.isNan(a) and !std.math.isNan(b) and a != b );
}

fn isnanFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return Value.fromBool(std.math.isNan(try asFloat(args[0])) );
}

fn isnormalFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return Value.fromBool(std.math.isNormal(try asFloat(args[0])) );
}

fn isunorderedFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return Value.fromBool(std.math.isNan(a) or std.math.isNan(b) );
}

fn signbitFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return Value.fromBool(std.math.signbit(try asFloat(args[0])) );
}


pub fn register(vm: *VMState) !void {
    floor_n = .{ .name = "__floor", .func = floorFn, .arity = 1 };
    ceil_n = .{ .name = "__ceil", .func = ceilFn, .arity = 1 };
    round_n = .{ .name = "__round", .func = roundFn, .arity = 1 };
    sqrt_n = .{ .name = "__sqrt", .func = sqrtFn, .arity = 1 };
    min_n = .{ .name = "__min", .func = minFn, .arity = 1 };
    max_n = .{ .name = "__max", .func = maxFn, .arity = 1 };
    pow_n = .{ .name = "__pow", .func = powFn, .arity = 2 };
    random_n = .{ .name = "__random", .func = randomFn, .arity = 0 };
    sin_n = .{ .name = "__sin", .func = sinFn, .arity = 1 };
    cos_n = .{ .name = "__cos", .func = cosFn, .arity = 1 };
    tan_n = .{ .name = "__tan", .func = tanFn, .arity = 1 };
    asin_n = .{ .name = "__asin", .func = asinFn, .arity = 1 };
    acos_n = .{ .name = "__acos", .func = acosFn, .arity = 1 };
    atan_n = .{ .name = "__atan", .func = atanFn, .arity = 1 };
    atan2_n = .{ .name = "__atan2", .func = atan2Fn, .arity = 2 };
    log_n = .{ .name = "__log", .func = logFn, .arity = 1 };
    log10_n = .{ .name = "__log10", .func = log10Fn, .arity = 1 };
    log2_n = .{ .name = "__log2", .func = log2Fn, .arity = 1 };
    exp_n = .{ .name = "__exp", .func = expFn, .arity = 1 };
    cbrt_n = .{ .name = "__cbrt", .func = cbrtFn, .arity = 1 };
    trunc_n = .{ .name = "__trunc", .func = truncFn, .arity = 1 };
    sign_n = .{ .name = "__sign", .func = signFn, .arity = 1 };

    try vm.defineGlobal("__floor", .{ .native = &floor_n });
    try vm.defineGlobal("__ceil", .{ .native = &ceil_n });
    try vm.defineGlobal("__round", .{ .native = &round_n });
    try vm.defineGlobal("__sqrt", .{ .native = &sqrt_n });
    try vm.defineGlobal("__min", .{ .native = &min_n });
    try vm.defineGlobal("__max", .{ .native = &max_n });
    try vm.defineGlobal("__pow", .{ .native = &pow_n });
    try vm.defineGlobal("__random", .{ .native = &random_n });
    try vm.defineGlobal("__sin", .{ .native = &sin_n });
    try vm.defineGlobal("__cos", .{ .native = &cos_n });
    try vm.defineGlobal("__tan", .{ .native = &tan_n });
    try vm.defineGlobal("__asin", .{ .native = &asin_n });
    try vm.defineGlobal("__acos", .{ .native = &acos_n });
    try vm.defineGlobal("__atan", .{ .native = &atan_n });
    try vm.defineGlobal("__atan2", .{ .native = &atan2_n });
    try vm.defineGlobal("__log", .{ .native = &log_n });
    try vm.defineGlobal("__log10", .{ .native = &log10_n });
    try vm.defineGlobal("__log2", .{ .native = &log2_n });
    try vm.defineGlobal("__exp", .{ .native = &exp_n });
    try vm.defineGlobal("__cbrt", .{ .native = &cbrt_n });
    try vm.defineGlobal("__trunc", .{ .native = &trunc_n });
    try vm.defineGlobal("__sign", .{ .native = &sign_n });
    acosh_n = .{ .name = "__acosh", .func = acoshFn, .arity = 1 };
    try vm.defineGlobal("__acosh", .{ .native = &acosh_n });
    asinh_n = .{ .name = "__asinh", .func = asinhFn, .arity = 1 };
    try vm.defineGlobal("__asinh", .{ .native = &asinh_n });
    atanh_n = .{ .name = "__atanh", .func = atanhFn, .arity = 1 };
    try vm.defineGlobal("__atanh", .{ .native = &atanh_n });
    copysign_n = .{ .name = "__copysign", .func = copysignFn, .arity = 2 };
    try vm.defineGlobal("__copysign", .{ .native = &copysign_n });
    cosh_n = .{ .name = "__cosh", .func = coshFn, .arity = 1 };
    try vm.defineGlobal("__cosh", .{ .native = &cosh_n });
    erf_n = .{ .name = "__erf", .func = erfFn, .arity = 1 };
    try vm.defineGlobal("__erf", .{ .native = &erf_n });
    erfc_n = .{ .name = "__erfc", .func = erfcFn, .arity = 1 };
    try vm.defineGlobal("__erfc", .{ .native = &erfc_n });
    exp2_n = .{ .name = "__exp2", .func = exp2Fn, .arity = 1 };
    try vm.defineGlobal("__exp2", .{ .native = &exp2_n });
    expm1_n = .{ .name = "__expm1", .func = expm1Fn, .arity = 1 };
    try vm.defineGlobal("__expm1", .{ .native = &expm1_n });
    fabs_n = .{ .name = "__fabs", .func = fabsFn, .arity = 1 };
    try vm.defineGlobal("__fabs", .{ .native = &fabs_n });
    fdim_n = .{ .name = "__fdim", .func = fdimFn, .arity = 2 };
    try vm.defineGlobal("__fdim", .{ .native = &fdim_n });
    fma_n = .{ .name = "__fma", .func = fmaFn, .arity = 3 };
    try vm.defineGlobal("__fma", .{ .native = &fma_n });
    fmax_n = .{ .name = "__fmax", .func = fmaxFn, .arity = 2 };
    try vm.defineGlobal("__fmax", .{ .native = &fmax_n });
    fmin_n = .{ .name = "__fmin", .func = fminFn, .arity = 2 };
    try vm.defineGlobal("__fmin", .{ .native = &fmin_n });
    fmod_n = .{ .name = "__fmod", .func = fmodFn, .arity = 2 };
    try vm.defineGlobal("__fmod", .{ .native = &fmod_n });
    frexp_n = .{ .name = "__frexp", .func = frexpFn, .arity = 1 };
    try vm.defineGlobal("__frexp", .{ .native = &frexp_n });
    hypot_n = .{ .name = "__hypot", .func = hypotFn, .arity = 2 };
    try vm.defineGlobal("__hypot", .{ .native = &hypot_n });
    ilogb_n = .{ .name = "__ilogb", .func = ilogbFn, .arity = 1 };
    try vm.defineGlobal("__ilogb", .{ .native = &ilogb_n });
    ldexp_n = .{ .name = "__ldexp", .func = ldexpFn, .arity = 2 };
    try vm.defineGlobal("__ldexp", .{ .native = &ldexp_n });
    lgamma_n = .{ .name = "__lgamma", .func = lgammaFn, .arity = 1 };
    try vm.defineGlobal("__lgamma", .{ .native = &lgamma_n });
    llrint_n = .{ .name = "__llrint", .func = llrintFn, .arity = 1 };
    try vm.defineGlobal("__llrint", .{ .native = &llrint_n });
    llround_n = .{ .name = "__llround", .func = llroundFn, .arity = 1 };
    try vm.defineGlobal("__llround", .{ .native = &llround_n });
    log1p_n = .{ .name = "__log1p", .func = log1pFn, .arity = 1 };
    try vm.defineGlobal("__log1p", .{ .native = &log1p_n });
    logb_n = .{ .name = "__logb", .func = logbFn, .arity = 1 };
    try vm.defineGlobal("__logb", .{ .native = &logb_n });
    lrint_n = .{ .name = "__lrint", .func = lrintFn, .arity = 1 };
    try vm.defineGlobal("__lrint", .{ .native = &lrint_n });
    lround_n = .{ .name = "__lround", .func = lroundFn, .arity = 1 };
    try vm.defineGlobal("__lround", .{ .native = &lround_n });
    modf_n = .{ .name = "__modf", .func = modfFn, .arity = 1 };
    try vm.defineGlobal("__modf", .{ .native = &modf_n });
    nan_n = .{ .name = "__nan", .func = nanFn, .arity = 1 };
    try vm.defineGlobal("__nan", .{ .native = &nan_n });
    nearbyint_n = .{ .name = "__nearbyint", .func = nearbyintFn, .arity = 1 };
    try vm.defineGlobal("__nearbyint", .{ .native = &nearbyint_n });
    nextafter_n = .{ .name = "__nextafter", .func = nextafterFn, .arity = 2 };
    try vm.defineGlobal("__nextafter", .{ .native = &nextafter_n });
    nexttoward_n = .{ .name = "__nexttoward", .func = nexttowardFn, .arity = 2 };
    try vm.defineGlobal("__nexttoward", .{ .native = &nexttoward_n });
    remainder_n = .{ .name = "__remainder", .func = remainderFn, .arity = 2 };
    try vm.defineGlobal("__remainder", .{ .native = &remainder_n });
    remquo_n = .{ .name = "__remquo", .func = remquoFn, .arity = 2 };
    try vm.defineGlobal("__remquo", .{ .native = &remquo_n });
    rint_n = .{ .name = "__rint", .func = rintFn, .arity = 1 };
    try vm.defineGlobal("__rint", .{ .native = &rint_n });
    scalbln_n = .{ .name = "__scalbln", .func = scalblnFn, .arity = 2 };
    try vm.defineGlobal("__scalbln", .{ .native = &scalbln_n });
    scalbn_n = .{ .name = "__scalbn", .func = scalbnFn, .arity = 2 };
    try vm.defineGlobal("__scalbn", .{ .native = &scalbn_n });
    sinh_n = .{ .name = "__sinh", .func = sinhFn, .arity = 1 };
    try vm.defineGlobal("__sinh", .{ .native = &sinh_n });
    tanh_n = .{ .name = "__tanh", .func = tanhFn, .arity = 1 };
    try vm.defineGlobal("__tanh", .{ .native = &tanh_n });
    tgamma_n = .{ .name = "__tgamma", .func = tgammaFn, .arity = 1 };
    try vm.defineGlobal("__tgamma", .{ .native = &tgamma_n });
    fpclassify_n = .{ .name = "__fpclassify", .func = fpclassifyFn, .arity = 1 };
    try vm.defineGlobal("__fpclassify", .{ .native = &fpclassify_n });
    isfinite_n = .{ .name = "__isfinite", .func = isfiniteFn, .arity = 1 };
    try vm.defineGlobal("__isfinite", .{ .native = &isfinite_n });
    isgreater_n = .{ .name = "__isgreater", .func = isgreaterFn, .arity = 2 };
    try vm.defineGlobal("__isgreater", .{ .native = &isgreater_n });
    isgreaterequal_n = .{ .name = "__isgreaterequal", .func = isgreaterequalFn, .arity = 2 };
    try vm.defineGlobal("__isgreaterequal", .{ .native = &isgreaterequal_n });
    isinf_n = .{ .name = "__isinf", .func = isinfFn, .arity = 1 };
    try vm.defineGlobal("__isinf", .{ .native = &isinf_n });
    isless_n = .{ .name = "__isless", .func = islessFn, .arity = 2 };
    try vm.defineGlobal("__isless", .{ .native = &isless_n });
    islessequal_n = .{ .name = "__islessequal", .func = islessequalFn, .arity = 2 };
    try vm.defineGlobal("__islessequal", .{ .native = &islessequal_n });
    islessgreater_n = .{ .name = "__islessgreater", .func = islessgreaterFn, .arity = 2 };
    try vm.defineGlobal("__islessgreater", .{ .native = &islessgreater_n });
    isnan_n = .{ .name = "__isnan", .func = isnanFn, .arity = 1 };
    try vm.defineGlobal("__isnan", .{ .native = &isnan_n });
    isnormal_n = .{ .name = "__isnormal", .func = isnormalFn, .arity = 1 };
    try vm.defineGlobal("__isnormal", .{ .native = &isnormal_n });
    isunordered_n = .{ .name = "__isunordered", .func = isunorderedFn, .arity = 2 };
    try vm.defineGlobal("__isunordered", .{ .native = &isunordered_n });
    signbit_n = .{ .name = "__signbit", .func = signbitFn, .arity = 1 };
    try vm.defineGlobal("__signbit", .{ .native = &signbit_n });

    huge_val_n = .{ .name = "__hugeVal", .func = hugeValFn, .arity = 0 };
    try vm.defineGlobal("__hugeVal", .{ .native = &huge_val_n });
    infinity_n = .{ .name = "__infinity", .func = infinityFn, .arity = 0 };
    try vm.defineGlobal("__infinity", .{ .native = &infinity_n });
    nan_value_n = .{ .name = "__nanValue", .func = nanValueFn, .arity = 0 };
    try vm.defineGlobal("__nanValue", .{ .native = &nan_value_n });

    try vm.defineGlobal("HUGE_VAL", .{ .f64 = std.math.inf(f64) });
    try vm.defineGlobal("INFINITY", .{ .f64 = std.math.inf(f64) });
    try vm.defineGlobal("NAN", .{ .f64 = std.math.nan(f64) });
    try vm.defineGlobal("FP_INFINITE", .{ .i64 = 1 });
    try vm.defineGlobal("FP_NAN", .{ .i64 = 0 });
    try vm.defineGlobal("FP_NORMAL", .{ .i64 = 4 });
    try vm.defineGlobal("FP_SUBNORMAL", .{ .i64 = 3 });
    try vm.defineGlobal("FP_ZERO", .{ .i64 = 2 });
    try vm.defineGlobal("MATH_ERRNO", .{ .i64 = 1 });
    try vm.defineGlobal("MATH_ERREXCEPT", .{ .i64 = 2 });
    try vm.defineGlobal("math_errhandling", .{ .i64 = 3 });

}
