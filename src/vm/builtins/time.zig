const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var now_n: NativeFunction = undefined;
var nanoTime_n: NativeFunction = undefined;
var sleep_n: NativeFunction = undefined;

fn nowFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .float = @floatFromInt(std.time.milliTimestamp()) };
}

fn nanoTimeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .float = @floatFromInt(std.time.nanoTimestamp()) };
}

fn sleepFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const ms: u64 = switch (args[0]) {
        .int => |n| @intCast(n),
        .float => |f| @intFromFloat(f),
        else => return error.TypeError,
    };
    std.Thread.sleep(ms * std.time.ns_per_ms);
    return .{ .int = 0 };
}

pub fn register(vm: *VMState) !void {
    now_n = .{ .name = "__now", .func = nowFn, .arity = 0 };
    nanoTime_n = .{ .name = "__nanoTime", .func = nanoTimeFn, .arity = 0 };
    sleep_n = .{ .name = "__sleep", .func = sleepFn, .arity = 1 };

    try vm.globals.put("__now", .{ .native = &now_n });
    try vm.globals.put("__nanoTime", .{ .native = &nanoTime_n });
    try vm.globals.put("__sleep", .{ .native = &sleep_n });
}
