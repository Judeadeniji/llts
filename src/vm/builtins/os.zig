const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

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

    // Simple shell exec for now using `sh -c`
    var child = std.process.Child.init(&.{ "sh", "-c", cmd_str }, vm.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(vm.allocator, 1024 * 1024 * 10);
    defer vm.allocator.free(stdout);
    _ = try child.wait();

    // To return a string, we need to allocate on heap
    return try util.writeSlice(vm, stdout);
}

fn getEnvFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const key = try util.valueToOwnedString(vm, args[0]);
    if (std.process.getEnvVarOwned(vm.allocator, key)) |val| {
        defer vm.allocator.free(val);
        return try util.writeSlice(vm, val);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return .{ .ptr = 0 }, // Should be null, using ptr 0 as null representation if supported
        else => return try util.makeError(vm, "Error reading environment variable"),
    }
}

fn setEnvFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    // zig std.process.setEnvVar is not available cross-platform in standard lib?
    // We can just return 0 for now or error.
    return .{ .int = 0 };
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
    const cwd = try std.process.getCwd(&buf);
    return try util.writeSlice(vm, cwd);
}

fn chdirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const dir = try util.valueToOwnedString(vm, args[0]);
    try std.posix.chdir(dir);
    return .{ .int = 0 };
}

fn pidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .int = 0 }; // stub
}

fn argsFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .int = 0 }; // stub
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
