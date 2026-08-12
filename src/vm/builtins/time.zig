const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var now_n: NativeFunction = undefined;
var sleep_n: NativeFunction = undefined;

fn asNanos(v: Value) !f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
        else => error.TypeError,
    };
}

/// Unix time in nanoseconds (float — matches std/time.lls Duration/Time encoding).
fn nowFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .float = @floatFromInt(std.time.nanoTimestamp()) };
}

/// Sleep for `d` nanoseconds (Go: time.Sleep(d Duration)).
fn sleepFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const ns_f = try asNanos(args[0]);
    if (ns_f <= 0) return .{ .int = 0 };
    const ns: u64 = @intFromFloat(@min(ns_f, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
    std.Thread.sleep(ns);
    return .{ .int = 0 };
}

pub fn register(vm: *VMState) !void {
    now_n = .{ .name = "__now", .func = nowFn, .arity = 0 };
    sleep_n = .{ .name = "__sleep", .func = sleepFn, .arity = 1 };

    try vm.globals.put("__now", .{ .native = &now_n });
    try vm.globals.put("__sleep", .{ .native = &sleep_n });
}
