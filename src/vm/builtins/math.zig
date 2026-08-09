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

fn minMax(vm: *VMState, args: []Value, want_min: bool) !Value {
    if (args.len < 1) return error.ArityError;
    const ptr = try util.asPtr(args[0]);
    const len = vm.memory[@intCast(ptr - 1)];
    if (len <= 0) return .{ .int = 0 };
    var best = vm.memory[@intCast(ptr)];
    var i: i32 = 1;
    while (i < len) : (i += 1) {
        const n = vm.memory[@intCast(ptr + i)];
        if (want_min) {
            if (n < best) best = n;
        } else {
            if (n > best) best = n;
        }
    }
    return .{ .int = best };
}

fn minFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    return try minMax(vm, args, true);
}

fn maxFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    return try minMax(vm, args, false);
}

fn powFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const a = try asFloat(args[0]);
    const b = try asFloat(args[1]);
    return .{ .int = @intFromFloat(std.math.pow(f64, a, b)) };
}

pub fn register(vm: *VMState) !void {
    floor_n = .{ .name = "__floor", .func = floorFn, .arity = 1 };
    ceil_n = .{ .name = "__ceil", .func = ceilFn, .arity = 1 };
    round_n = .{ .name = "__round", .func = roundFn, .arity = 1 };
    sqrt_n = .{ .name = "__sqrt", .func = sqrtFn, .arity = 1 };
    min_n = .{ .name = "__min", .func = minFn, .arity = 1 };
    max_n = .{ .name = "__max", .func = maxFn, .arity = 1 };
    pow_n = .{ .name = "__pow", .func = powFn, .arity = 2 };

    try vm.globals.put("__floor", .{ .native = &floor_n });
    try vm.globals.put("__ceil", .{ .native = &ceil_n });
    try vm.globals.put("__round", .{ .native = &round_n });
    try vm.globals.put("__sqrt", .{ .native = &sqrt_n });
    try vm.globals.put("__min", .{ .native = &min_n });
    try vm.globals.put("__max", .{ .native = &max_n });
    try vm.globals.put("__pow", .{ .native = &pow_n });
}
