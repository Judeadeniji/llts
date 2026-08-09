const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var read_file_n: NativeFunction = undefined;
var read_line_n: NativeFunction = undefined;
var write_file_n: NativeFunction = undefined;
var append_file_n: NativeFunction = undefined;
var delete_file_n: NativeFunction = undefined;
var exists_n: NativeFunction = undefined;

fn readFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(vm.allocator, path, 16 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(vm.allocator, "{s}", .{@errorName(err)});
        defer vm.allocator.free(msg);
        return try util.makeError(vm, msg);
    };
    defer vm.allocator.free(content);
    return try util.writeString(vm, content);
}

fn readLineFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    var buf: [1024]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch |err| {
        const msg = try std.fmt.allocPrint(vm.allocator, "{s}", .{@errorName(err)});
        defer vm.allocator.free(msg);
        return try util.makeError(vm, msg);
    };
    var str = buf[0..n];
    if (std.mem.endsWith(u8, str, "\n")) str = str[0 .. str.len - 1];
    if (std.mem.endsWith(u8, str, "\r")) str = str[0 .. str.len - 1];
    return try util.writeString(vm, str);
}

fn writeFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(content);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
    return .null;
}

fn appendFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(content);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
    return .null;
}

fn deleteFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    try std.fs.cwd().deleteFile(path);
    return .null;
}

fn existsFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return .{ .bool = false };
    return .{ .bool = true };
}

pub fn register(vm: *VMState) !void {
    read_file_n = .{ .name = "__readFile", .func = readFileFn, .arity = 1 };
    read_line_n = .{ .name = "__readLine", .func = readLineFn, .arity = 0 };
    write_file_n = .{ .name = "__writeFile", .func = writeFileFn, .arity = 2 };
    append_file_n = .{ .name = "__appendFile", .func = appendFileFn, .arity = 2 };
    delete_file_n = .{ .name = "__deleteFile", .func = deleteFileFn, .arity = 1 };
    exists_n = .{ .name = "__exists", .func = existsFn, .arity = 1 };

    try vm.globals.put("__readFile", .{ .native = &read_file_n });
    try vm.globals.put("__readLine", .{ .native = &read_line_n });
    try vm.globals.put("__writeFile", .{ .native = &write_file_n });
    try vm.globals.put("__appendFile", .{ .native = &append_file_n });
    try vm.globals.put("__deleteFile", .{ .native = &delete_file_n });
    try vm.globals.put("__exists", .{ .native = &exists_n });
}
