const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var read_file_n: NativeFunction = undefined;
var read_file_buffer_n: NativeFunction = undefined;
var read_line_n: NativeFunction = undefined;
var write_file_n: NativeFunction = undefined;
var write_file_buffer_n: NativeFunction = undefined;
var append_file_n: NativeFunction = undefined;
var delete_file_n: NativeFunction = undefined;
var exists_n: NativeFunction = undefined;
var mkdir_n: NativeFunction = undefined;
var mkdir_all_n: NativeFunction = undefined;
var read_dir_n: NativeFunction = undefined;
var stat_n: NativeFunction = undefined;
var rename_n: NativeFunction = undefined;
var copy_file_n: NativeFunction = undefined;
var symlink_n: NativeFunction = undefined;
var readlink_n: NativeFunction = undefined;
var realpath_n: NativeFunction = undefined;
var chmod_n: NativeFunction = undefined;

fn readFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(vm.allocator, path, 16 * 1024 * 1024) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    defer vm.allocator.free(content);
    return try util.writeSlice(vm, content);
}

fn readFileBufferFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(vm.allocator, path, 256 * 1024 * 1024) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    defer vm.allocator.free(content);
    
    const buf = try vm.allocBuffer();
    try buf.bytes.appendSlice(vm.allocator, content);
    return .{ .buffer = buf };
}

fn readLineFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const fd: std.posix.fd_t = if (args.len >= 1)
        @intCast(try util.asInt(args[0]))
    else
        std.posix.STDIN_FILENO;
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| {
        return try util.makeErrorWithPayload(vm, "IoError", try util.writeSlice(vm, @errorName(err)));
    };
    if (n == 0) return .null;
    var str = buf[0..n];
    if (std.mem.indexOfScalar(u8, str, '\n')) |nl| {
        str = str[0..nl];
    }
    if (std.mem.endsWith(u8, str, "\r")) str = str[0 .. str.len - 1];
    return try util.writeSlice(vm, str);
}

fn writeFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(content);
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return .null;
}

fn writeFileBufferFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    if (args[1] != .buffer) return error.TypeError;

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    defer file.close();
    file.writeAll(args[1].buffer.bytes.items) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return .null;
}

fn appendFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const content = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(content);
    const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    defer file.close();
    file.seekFromEnd(0) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    file.writeAll(content) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return .null;
}

fn deleteFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
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

fn mkdirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.fs.cwd().makeDir(path) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return .null;
}

fn mkdirAllFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.fs.cwd().makePath(path) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return .null;
}

fn readDirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    defer dir.close();

    var it = dir.iterate();
    var list: std.ArrayListUnmanaged(Value) = .empty;
    defer list.deinit(vm.allocator);

    while (it.next() catch return try util.makeError(vm, "IoError")) |entry| {
        const name_val = try util.writeSlice(vm, entry.name);
        try list.append(vm.allocator, name_val);
    }
    return try util.writeArray(vm, list.items);
}

fn statFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);

    const stat = std.fs.cwd().statFile(path) catch |err| {
        return try util.makeIoError(vm, err, path);
    };

    var list: std.ArrayListUnmanaged(Value) = .empty;
    defer list.deinit(vm.allocator);
    try list.append(vm.allocator, .{ .float = @floatFromInt(stat.size) });
    try list.append(vm.allocator, .{ .float = @floatFromInt(@divTrunc(stat.mtime, 1000000)) }); // ms
    try list.append(vm.allocator, .{ .float = @floatFromInt(@divTrunc(stat.atime, 1000000)) });
    try list.append(vm.allocator, .{ .float = @floatFromInt(@divTrunc(stat.ctime, 1000000)) });
    const kind: i32 = switch (stat.kind) {
        .file => 1,
        .directory => 2,
        .sym_link => 3,
        else => 0,
    };
    try list.append(vm.allocator, .{ .int = kind });
    return try util.writeArray(vm, list.items);
}

fn renameFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const old_path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(old_path);
    const new_path = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(new_path);
    std.fs.cwd().rename(old_path, new_path) catch |err| {
        return try util.makeIoError(vm, err, old_path);
    };
    return .null;
}

fn copyFileFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const src = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(src);
    const dst = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(dst);
    std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch |err| {
        return try util.makeIoError(vm, err, src);
    };
    return .null;
}

fn symlinkFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const target = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(target);
    const link_path = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(link_path);
    std.fs.cwd().symLink(target, link_path, .{}) catch |err| {
        return try util.makeIoError(vm, err, link_path);
    };
    return .null;
}

fn readlinkFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = std.fs.cwd().readLink(path, &buf) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return try util.writeSlice(vm, link);
}

fn realpathFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.fs.cwd().realpath(path, &buf) catch |err| {
        return try util.makeIoError(vm, err, path);
    };
    return try util.writeSlice(vm, real);
}

fn chmodFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    // zig std.fs doesn't have a simple chmod in standard API across all platforms
    return .{ .int = 0 }; // stub
}

pub fn register(vm: *VMState) !void {
    read_file_n = .{ .name = "__readFile", .func = readFileFn, .arity = 1 };
    read_file_buffer_n = .{ .name = "__readFileBuffer", .func = readFileBufferFn, .arity = 1 };
    read_line_n = .{ .name = "__readLine", .func = readLineFn, .arity = -1 };
    write_file_n = .{ .name = "__writeFile", .func = writeFileFn, .arity = 2 };
    write_file_buffer_n = .{ .name = "__writeFileBuffer", .func = writeFileBufferFn, .arity = 2 };
    append_file_n = .{ .name = "__appendFile", .func = appendFileFn, .arity = 2 };
    delete_file_n = .{ .name = "__deleteFile", .func = deleteFileFn, .arity = 1 };
    exists_n = .{ .name = "__exists", .func = existsFn, .arity = 1 };
    mkdir_n = .{ .name = "__mkdir", .func = mkdirFn, .arity = 1 };
    mkdir_all_n = .{ .name = "__mkdirAll", .func = mkdirAllFn, .arity = 1 };
    read_dir_n = .{ .name = "__readDir", .func = readDirFn, .arity = 1 };
    stat_n = .{ .name = "__stat", .func = statFn, .arity = 1 };
    rename_n = .{ .name = "__rename", .func = renameFn, .arity = 2 };
    copy_file_n = .{ .name = "__copyFile", .func = copyFileFn, .arity = 2 };
    symlink_n = .{ .name = "__symlink", .func = symlinkFn, .arity = 2 };
    readlink_n = .{ .name = "__readlink", .func = readlinkFn, .arity = 1 };
    realpath_n = .{ .name = "__realpath", .func = realpathFn, .arity = 1 };
    chmod_n = .{ .name = "__chmod", .func = chmodFn, .arity = 2 };

    try vm.defineGlobal("__readFile", .{ .native = &read_file_n });
    try vm.defineGlobal("__readFileBuffer", .{ .native = &read_file_buffer_n });
    try vm.defineGlobal("__readLine", .{ .native = &read_line_n });
    try vm.defineGlobal("__writeFile", .{ .native = &write_file_n });
    try vm.defineGlobal("__writeFileBuffer", .{ .native = &write_file_buffer_n });
    try vm.defineGlobal("__appendFile", .{ .native = &append_file_n });
    try vm.defineGlobal("__deleteFile", .{ .native = &delete_file_n });
    try vm.defineGlobal("__exists", .{ .native = &exists_n });
    try vm.defineGlobal("__mkdir", .{ .native = &mkdir_n });
    try vm.defineGlobal("__mkdirAll", .{ .native = &mkdir_all_n });
    try vm.defineGlobal("__readDir", .{ .native = &read_dir_n });
    try vm.defineGlobal("__stat", .{ .native = &stat_n });
    try vm.defineGlobal("__rename", .{ .native = &rename_n });
    try vm.defineGlobal("__copyFile", .{ .native = &copy_file_n });
    try vm.defineGlobal("__symlink", .{ .native = &symlink_n });
    try vm.defineGlobal("__readlink", .{ .native = &readlink_n });
    try vm.defineGlobal("__realpath", .{ .native = &realpath_n });
    try vm.defineGlobal("__chmod", .{ .native = &chmod_n });
}
