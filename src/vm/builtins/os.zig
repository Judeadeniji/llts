const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

extern "c" fn setenv(name: [*:0]const u8, val: [*:0]const u8, overwrite: c_int) c_int;

var exec_n: NativeFunction = undefined;
var getEnv_n: NativeFunction = undefined;
var setEnv_n: NativeFunction = undefined;
var exit_n: NativeFunction = undefined;
var cwd_n: NativeFunction = undefined;
var chdir_n: NativeFunction = undefined;
var pid_n: NativeFunction = undefined;
var args_n: NativeFunction = undefined;
var platform_n: NativeFunction = undefined;

fn execFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const cmd_str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(cmd_str);

    var child = std.process.Child.init(&.{ "sh", "-c", cmd_str }, vm.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        return try util.makeErrorWithPayload(vm, "ExecError", try util.writeSlice(vm, @errorName(err)));
    };
    const stdout = child.stdout.?.readToEndAlloc(vm.allocator, 1024 * 1024 * 10) catch |err| {
        _ = child.wait() catch {};
        return try util.makeErrorWithPayload(vm, "ExecError", try util.writeSlice(vm, @errorName(err)));
    };
    defer vm.allocator.free(stdout);
    _ = child.wait() catch |err| {
        return try util.makeErrorWithPayload(vm, "ExecError", try util.writeSlice(vm, @errorName(err)));
    };

    return try util.writeSlice(vm, stdout);
}

fn getEnvFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const key = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(key);
    if (std.process.getEnvVarOwned(vm.allocator, key)) |val| {
        defer vm.allocator.free(val);
        return try util.writeSlice(vm, val);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return .null,
        else => return try util.makeError(vm, "EnvError"),
    }
}

fn setEnvFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const key = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(key);
    const val = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(val);

    const key_z = try vm.allocator.dupeZ(u8, key);
    defer vm.allocator.free(key_z);
    const val_z = try vm.allocator.dupeZ(u8, val);
    defer vm.allocator.free(val_z);

    if (setenv(key_z.ptr, val_z.ptr, 1) != 0) {
        return try util.makeError(vm, "EnvError");
    }
    return .null;
}

fn exitFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    const code: u8 = if (args.len > 0) @intCast(try util.asInt(args[0])) else 0;
    std.process.exit(code);
}

fn cwdFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&buf) catch |err| {
        return try util.makeErrorWithPayload(vm, "CwdError", try util.writeSlice(vm, @errorName(err)));
    };
    return try util.writeSlice(vm, cwd);
}

fn chdirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const dir = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(dir);
    std.posix.chdir(dir) catch {
        return try util.makeErrorWithPayload(vm, "ChdirError", try util.writeSlice(vm, dir));
    };
    return .null;
}

fn pidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .int = std.os.linux.getpid() };
}

fn argsFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    // Program path as args[0] (like C argv[0]), then any trailing CLI args
    // forwarded by the host.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    try items.append(vm.allocator, try util.writeSlice(vm, vm.script_path));
    for (vm.script_args) |a| {
        try items.append(vm.allocator, try util.writeSlice(vm, a));
    }
    return try util.writeArray(vm, items.items);
}

fn platformFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const os_tag = @tagName(@import("builtin").os.tag);
    return try util.writeSlice(vm, os_tag);
}

pub fn register(vm: *VMState) !void {
    exec_n = .{ .name = "__exec", .func = execFn, .arity = 1 };
    getEnv_n = .{ .name = "__getEnv", .func = getEnvFn, .arity = 1 };
    setEnv_n = .{ .name = "__setEnv", .func = setEnvFn, .arity = 2 };
    exit_n = .{ .name = "__exit", .func = exitFn, .arity = 1 };
    cwd_n = .{ .name = "__cwd", .func = cwdFn, .arity = 0 };
    chdir_n = .{ .name = "__chdir", .func = chdirFn, .arity = 1 };
    pid_n = .{ .name = "__pid", .func = pidFn, .arity = 0 };
    args_n = .{ .name = "__args", .func = argsFn, .arity = 0 };
    platform_n = .{ .name = "__platform", .func = platformFn, .arity = 0 };

    try vm.globals.put("__exec", .{ .native = &exec_n });
    try vm.globals.put("__getEnv", .{ .native = &getEnv_n });
    try vm.globals.put("__setEnv", .{ .native = &setEnv_n });
    try vm.globals.put("__exit", .{ .native = &exit_n });
    try vm.globals.put("__cwd", .{ .native = &cwd_n });
    try vm.globals.put("__chdir", .{ .native = &chdir_n });
    try vm.globals.put("__pid", .{ .native = &pid_n });
    try vm.globals.put("__args", .{ .native = &args_n });
    try vm.globals.put("__platform", .{ .native = &platform_n });
}
