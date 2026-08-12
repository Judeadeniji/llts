const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

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
        .int => |n| @floatFromInt(n),
        .float => |n| n,
        .ptr => |p| @floatFromInt(p),
        .bool => |b| @floatFromInt(@intFromBool(b)),
        else => error.TypeError,
    };
}

fn floorFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .int = @intFromFloat(@floor(try asFloat(args[0]))) };
}

fn ceilFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .int = @intFromFloat(@ceil(try asFloat(args[0]))) };
}

fn roundFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .int = @intFromFloat(@round(try asFloat(args[0]))) };
}

fn sqrtFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const val = try util.asInt(args[0]);
    if (val < 0) {
        return try util.makeError(vm, "Cannot take square root of negative number");
    }
    return .{ .int = @intFromFloat(@sqrt(@as(f64, @floatFromInt(val)))) };
}

fn minMax(vm: *VMState, args: []Value, find_max: bool) !Value {
    if (args.len < 1) return error.ArityError;
    const ptr = try util.asPtr(args[0]);
    const len = vm.memory[@intCast(ptr - 1)].int;
    if (len == 0) return .{ .float = std.math.inf(f64) * (if (find_max) @as(f64, -1) else @as(f64, 1)) };
    var best: f64 = switch (vm.memory[@intCast(ptr)]) {
        .float => |f| f,
        .int => |n| @floatFromInt(n),
        else => return error.TypeError,
    };
    var i: i32 = 1;
    while (i < len) : (i += 1) {
        const n: f64 = switch (vm.memory[@intCast(ptr + i)]) {
            .float => |f| f,
            .int => |m| @floatFromInt(m),
            else => return error.TypeError,
        };
        if (find_max and n > best) best = n;
        if (!find_max and n < best) best = n;
    }
    return .{ .float = best };
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
    return .{ .int = @intFromFloat(std.math.pow(f64, a, b)) };
}

fn randomFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const r = std.crypto.random.float(f64);
    return .{ .float = r };
}

fn sinFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.sin(try asFloat(args[0])) };
}

fn cosFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.cos(try asFloat(args[0])) };
}

fn tanFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.tan(try asFloat(args[0])) };
}

fn asinFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.asin(try asFloat(args[0])) };
}

fn acosFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.acos(try asFloat(args[0])) };
}

fn atanFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.atan(try asFloat(args[0])) };
}

fn atan2Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    return .{ .float = std.math.atan2(try asFloat(args[0]), try asFloat(args[1])) };
}

fn logFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = @log(try asFloat(args[0])) };
}

fn log10Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.log10(try asFloat(args[0])) };
}

fn log2Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.log2(try asFloat(args[0])) };
}

fn expFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.exp(try asFloat(args[0])) };
}

fn cbrtFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.cbrt(try asFloat(args[0])) };
}

fn truncFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    return .{ .float = std.math.trunc(try asFloat(args[0])) };
}

fn signFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const v = try asFloat(args[0]);
    if (v > 0) return .{ .int = 1 };
    if (v < 0) return .{ .int = -1 };
    return .{ .int = 0 };
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

    try vm.globals.put("__floor", .{ .native = &floor_n });
    try vm.globals.put("__ceil", .{ .native = &ceil_n });
    try vm.globals.put("__round", .{ .native = &round_n });
    try vm.globals.put("__sqrt", .{ .native = &sqrt_n });
    try vm.globals.put("__min", .{ .native = &min_n });
    try vm.globals.put("__max", .{ .native = &max_n });
    try vm.globals.put("__pow", .{ .native = &pow_n });
    try vm.globals.put("__random", .{ .native = &random_n });
    try vm.globals.put("__sin", .{ .native = &sin_n });
    try vm.globals.put("__cos", .{ .native = &cos_n });
    try vm.globals.put("__tan", .{ .native = &tan_n });
    try vm.globals.put("__asin", .{ .native = &asin_n });
    try vm.globals.put("__acos", .{ .native = &acos_n });
    try vm.globals.put("__atan", .{ .native = &atan_n });
    try vm.globals.put("__atan2", .{ .native = &atan2_n });
    try vm.globals.put("__log", .{ .native = &log_n });
    try vm.globals.put("__log10", .{ .native = &log10_n });
    try vm.globals.put("__log2", .{ .native = &log2_n });
    try vm.globals.put("__exp", .{ .native = &exp_n });
    try vm.globals.put("__cbrt", .{ .native = &cbrt_n });
    try vm.globals.put("__trunc", .{ .native = &trunc_n });
    try vm.globals.put("__sign", .{ .native = &sign_n });
}
