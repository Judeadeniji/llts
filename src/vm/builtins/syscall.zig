const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;
const linux = std.os.linux;

var call_n: NativeFunction = undefined;
var nr_n: NativeFunction = undefined;
var is_err_n: NativeFunction = undefined;
var errno_n: NativeFunction = undefined;
var err_name_n: NativeFunction = undefined;
var read_n: NativeFunction = undefined;
var write_n: NativeFunction = undefined;
var write_all_n: NativeFunction = undefined;
var open_n: NativeFunction = undefined;
var close_n: NativeFunction = undefined;
var lseek_n: NativeFunction = undefined;
var fsync_n: NativeFunction = undefined;
var pipe_n: NativeFunction = undefined;
var dup_n: NativeFunction = undefined;
var dup2_n: NativeFunction = undefined;
var getpid_n: NativeFunction = undefined;
var getppid_n: NativeFunction = undefined;
var getuid_n: NativeFunction = undefined;
var geteuid_n: NativeFunction = undefined;
var getgid_n: NativeFunction = undefined;
var getegid_n: NativeFunction = undefined;
var kill_n: NativeFunction = undefined;
var chdir_n: NativeFunction = undefined;
var getcwd_n: NativeFunction = undefined;
var unlink_n: NativeFunction = undefined;
var rename_n: NativeFunction = undefined;
var mkdir_n: NativeFunction = undefined;
var rmdir_n: NativeFunction = undefined;
var access_n: NativeFunction = undefined;
var chmod_n: NativeFunction = undefined;
var symlink_n: NativeFunction = undefined;
var readlink_n: NativeFunction = undefined;
var ftruncate_n: NativeFunction = undefined;
var umask_n: NativeFunction = undefined;
var nanosleep_n: NativeFunction = undefined;
var fcntl_n: NativeFunction = undefined;

fn asUsize(v: Value) !usize {
    const n = try util.asInt(v);
    return @bitCast(@as(isize, @intCast(n)));
}

fn rcToInt(rc: usize) i64 {
    return @bitCast(@as(isize, @bitCast(rc)));
}

fn makeSyscallError(vm: *VMState, err: anyerror) !Value {
    return try util.makeErrorWithPayload(vm, "SyscallError", try util.writeSlice(vm, @errorName(err)));
}

/// Raw Linux syscall: `call(nr, ...args)` via `__syscall(nr)` or `__syscall(nr, args_array)`.
/// Returns the kernel result as a signed int (values in -1..-4095 are -errno).
fn callFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (args.len < 1) return error.ArityError;

    const nr: usize = @intCast(try util.asInt(args[0]));
    var a: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
    var n: usize = 0;

    if (args.len >= 2) {
        switch (args[1]) {
            .ptr => |p| {
                const len: usize = @intCast(vm.slot(p - 1).*.int);
                if (len > 6) return error.ArityError;
                n = len;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    a[i] = try asUsize(vm.slot(p + @as(i32, @intCast(i))).*);
                }
            },
            else => {
                // Flat form: __syscall(nr, a1, a2, ...)
                n = args.len - 1;
                if (n > 6) return error.ArityError;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    a[i] = try asUsize(args[i + 1]);
                }
            },
        }
    }

    const sys: linux.SYS = @enumFromInt(nr);
    const rc = switch (n) {
        0 => linux.syscall0(sys),
        1 => linux.syscall1(sys, a[0]),
        2 => linux.syscall2(sys, a[0], a[1]),
        3 => linux.syscall3(sys, a[0], a[1], a[2]),
        4 => linux.syscall4(sys, a[0], a[1], a[2], a[3]),
        5 => linux.syscall5(sys, a[0], a[1], a[2], a[3], a[4]),
        else => linux.syscall6(sys, a[0], a[1], a[2], a[3], a[4], a[5]),
    };
    return .{ .int = rcToInt(rc) };
}

fn nrFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (args.len < 1) return error.ArityError;

    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(vm.allocator);
    const name = try util.valueToStr(vm, args[0], &tmp);

    inline for (@typeInfo(linux.SYS).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return .{ .int = @intCast(f.value) };
        }
    }
    return try util.makeErrorWithPayload(vm, "SyscallError", try util.writeSlice(vm, "UnknownSyscall"));
}

fn isErrFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const rc: usize = @bitCast(@as(isize, @intCast(try util.asInt(args[0]))));
    return .{ .bool = linux.E.init(rc) != .SUCCESS };
}

fn errnoFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const rc: usize = @bitCast(@as(isize, @intCast(try util.asInt(args[0]))));
    return .{ .int = @intFromEnum(linux.E.init(rc)) };
}

fn errNameFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const rc: usize = @bitCast(@as(isize, @intCast(try util.asInt(args[0]))));
    const e = linux.E.init(rc);
    if (e == .SUCCESS) return try util.writeSlice(vm, "");
    return try util.writeSlice(vm, @tagName(e));
}

fn readFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    const buf: []u8 = switch (args[1]) {
        .buffer => |b| b.bytes.items,
        .bytes => |b| vm.bytes.items[b.offset..][0..b.len],
        else => return error.TypeError,
    };
    const n = std.posix.read(fd, buf) catch |err| return try makeSyscallError(vm, err);
    return .{ .int = @intCast(n) };
}

fn writeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));

    if (args[1] == .buffer) {
        const n = std.posix.write(fd, args[1].buffer.bytes.items) catch |err| {
            return try makeSyscallError(vm, err);
        };
        return .{ .int = @intCast(n) };
    }
    if (args[1] == .bytes) {
        const b = args[1].bytes;
        const n = std.posix.write(fd, vm.bytes.items[b.offset..][0..b.len]) catch |err| {
            return try makeSyscallError(vm, err);
        };
        return .{ .int = @intCast(n) };
    }

    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(vm.allocator);
    const s = try util.valueToStr(vm, args[1], &tmp);
    const n = std.posix.write(fd, s) catch |err| return try makeSyscallError(vm, err);
    return .{ .int = @intCast(n) };
}

fn writeAllFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));

    var owned: ?[]u8 = null;
    defer if (owned) |o| vm.allocator.free(o);

    const bytes: []const u8 = if (args[1] == .buffer)
        args[1].buffer.bytes.items
    else if (args[1] == .bytes)
        vm.bytes.items[args[1].bytes.offset..][0..args[1].bytes.len]
    else blk: {
        owned = try util.valueToOwnedString(vm, args[1]);
        break :blk owned.?;
    };

    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch |err| return try makeSyscallError(vm, err);
        if (n == 0) return try util.makeErrorWithPayload(vm, "SyscallError", try util.writeSlice(vm, "ShortWrite"));
        remaining = remaining[n..];
    }
    return .{ .int = @intCast(bytes.len) };
}

fn openFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const flags_i: u32 = @intCast(try util.asInt(args[1]));
    const mode: std.posix.mode_t = if (args.len > 2) @intCast(try util.asInt(args[2])) else 0;
    const flags: std.posix.O = @bitCast(flags_i);
    const fd = std.posix.open(path, flags, mode) catch |err| return try makeSyscallError(vm, err);
    return .{ .int = @intCast(fd) };
}

fn closeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    std.posix.close(fd);
    return .null;
}

fn lseekFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    const offset: i64 = try util.asInt(args[1]);
    const whence: i32 = @intCast(try util.asInt(args[2]));
    switch (whence) {
        std.posix.SEEK.SET => std.posix.lseek_SET(fd, @intCast(offset)) catch |err| {
            return try makeSyscallError(vm, err);
        },
        std.posix.SEEK.CUR => std.posix.lseek_CUR(fd, offset) catch |err| {
            return try makeSyscallError(vm, err);
        },
        std.posix.SEEK.END => std.posix.lseek_END(fd, offset) catch |err| {
            return try makeSyscallError(vm, err);
        },
        else => return try util.makeErrorWithPayload(vm, "SyscallError", try util.writeSlice(vm, "INVAL")),
    }
    const pos = std.posix.lseek_CUR_get(fd) catch |err| return try makeSyscallError(vm, err);
    return .{ .int = @intCast(pos) };
}

fn fsyncFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    std.posix.fsync(fd) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn pipeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const fds = std.posix.pipe() catch |err| return try makeSyscallError(vm, err);
    return try util.writeArray(vm, &.{
        .{ .int = @intCast(fds[0]) },
        .{ .int = @intCast(fds[1]) },
    });
}

fn dupFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    const new_fd = std.posix.dup(fd) catch |err| return try makeSyscallError(vm, err);
    return .{ .int = @intCast(new_fd) };
}

fn dup2Fn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const old_fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    const new_fd: std.posix.fd_t = @intCast(try util.asInt(args[1]));
    std.posix.dup2(old_fd, new_fd) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn getpidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .int = @intCast(std.os.linux.getpid()) };
}

fn getppidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const rc = linux.syscall0(.getppid);
    return .{ .int = rcToInt(rc) };
}

fn getuidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .int = @intCast(std.posix.getuid()) };
}

fn geteuidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return .{ .int = @intCast(std.posix.geteuid()) };
}

fn getgidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    return .{ .int = rcToInt(linux.syscall0(.getgid)) };
}

fn getegidFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    return .{ .int = rcToInt(linux.syscall0(.getegid)) };
}

fn killFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const pid: std.posix.pid_t = @intCast(try util.asInt(args[0]));
    const sig: u8 = @intCast(try util.asInt(args[1]));
    std.posix.kill(pid, sig) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn chdirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.posix.chdir(path) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn getcwdFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch |err| return try makeSyscallError(vm, err);
    return try util.writeSlice(vm, cwd);
}

fn unlinkFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.posix.unlink(path) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn renameFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const old_p = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(old_p);
    const new_p = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(new_p);
    std.posix.rename(old_p, new_p) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn mkdirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const mode: std.posix.mode_t = if (args.len > 1) @intCast(try util.asInt(args[1])) else 0o755;
    std.posix.mkdir(path, mode) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn rmdirFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    std.posix.rmdir(path) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn accessFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const mode: u32 = if (args.len > 1) @intCast(try util.asInt(args[1])) else std.posix.F_OK;
    std.posix.access(path, mode) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn chmodFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    const mode: std.posix.mode_t = @intCast(try util.asInt(args[1]));
    std.posix.fchmodat(std.posix.AT.FDCWD, path, mode, 0) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn symlinkFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const target = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(target);
    const path = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(path);
    std.posix.symlink(target, path) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn readlinkFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const path = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = std.posix.readlink(path, &buf) catch |err| return try makeSyscallError(vm, err);
    return try util.writeSlice(vm, out);
}

fn ftruncateFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    const len: u64 = @intCast(try util.asInt(args[1]));
    std.posix.ftruncate(fd, len) catch |err| return try makeSyscallError(vm, err);
    return .null;
}

fn umaskFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    const mask: std.posix.mode_t = @intCast(try util.asInt(args[0]));
    const old = std.c.umask(mask);
    return .{ .int = @intCast(old) };
}

fn nanosleepFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    const sec: u64 = @intCast(try util.asInt(args[0]));
    const nsec: u64 = @intCast(try util.asInt(args[1]));
    std.posix.nanosleep(sec, nsec);
    return .null;
}

fn fcntlFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(try util.asInt(args[0]));
    const cmd: i32 = @intCast(try util.asInt(args[1]));
    const arg: usize = if (args.len > 2) try asUsize(args[2]) else 0;
    const rc = std.posix.fcntl(fd, cmd, arg) catch |err| return try makeSyscallError(vm, err);
    return .{ .int = @intCast(rc) };
}

fn putSys(vm: *VMState, comptime name: []const u8) !void {
    if (builtin.os.tag != .linux) return;
    if (!@hasField(linux.SYS, name)) return;
    const n = @intFromEnum(@field(linux.SYS, name));
    try vm.defineGlobal("__SYS_" ++ name, .{ .int = @intCast(n) });
}

fn putInt(vm: *VMState, name: []const u8, n: i64) !void {
    try vm.defineGlobal(name, .{ .int = n });
}

pub fn register(vm: *VMState) !void {
    call_n = .{ .name = "__syscall", .func = callFn, .arity = -1 };
    nr_n = .{ .name = "__sys_nr", .func = nrFn, .arity = 1 };
    is_err_n = .{ .name = "__sys_isError", .func = isErrFn, .arity = 1 };
    errno_n = .{ .name = "__sys_errno", .func = errnoFn, .arity = 1 };
    err_name_n = .{ .name = "__sys_errName", .func = errNameFn, .arity = 1 };
    read_n = .{ .name = "__sys_read", .func = readFn, .arity = 2 };
    write_n = .{ .name = "__sys_write", .func = writeFn, .arity = 2 };
    write_all_n = .{ .name = "__sys_writeAll", .func = writeAllFn, .arity = 2 };
    open_n = .{ .name = "__sys_open", .func = openFn, .arity = -1 };
    close_n = .{ .name = "__sys_close", .func = closeFn, .arity = 1 };
    lseek_n = .{ .name = "__sys_lseek", .func = lseekFn, .arity = 3 };
    fsync_n = .{ .name = "__sys_fsync", .func = fsyncFn, .arity = 1 };
    pipe_n = .{ .name = "__sys_pipe", .func = pipeFn, .arity = 0 };
    dup_n = .{ .name = "__sys_dup", .func = dupFn, .arity = 1 };
    dup2_n = .{ .name = "__sys_dup2", .func = dup2Fn, .arity = 2 };
    getpid_n = .{ .name = "__sys_getpid", .func = getpidFn, .arity = 0 };
    getppid_n = .{ .name = "__sys_getppid", .func = getppidFn, .arity = 0 };
    getuid_n = .{ .name = "__sys_getuid", .func = getuidFn, .arity = 0 };
    geteuid_n = .{ .name = "__sys_geteuid", .func = geteuidFn, .arity = 0 };
    getgid_n = .{ .name = "__sys_getgid", .func = getgidFn, .arity = 0 };
    getegid_n = .{ .name = "__sys_getegid", .func = getegidFn, .arity = 0 };
    kill_n = .{ .name = "__sys_kill", .func = killFn, .arity = 2 };
    chdir_n = .{ .name = "__sys_chdir", .func = chdirFn, .arity = 1 };
    getcwd_n = .{ .name = "__sys_getcwd", .func = getcwdFn, .arity = 0 };
    unlink_n = .{ .name = "__sys_unlink", .func = unlinkFn, .arity = 1 };
    rename_n = .{ .name = "__sys_rename", .func = renameFn, .arity = 2 };
    mkdir_n = .{ .name = "__sys_mkdir", .func = mkdirFn, .arity = -1 };
    rmdir_n = .{ .name = "__sys_rmdir", .func = rmdirFn, .arity = 1 };
    access_n = .{ .name = "__sys_access", .func = accessFn, .arity = -1 };
    chmod_n = .{ .name = "__sys_chmod", .func = chmodFn, .arity = 2 };
    symlink_n = .{ .name = "__sys_symlink", .func = symlinkFn, .arity = 2 };
    readlink_n = .{ .name = "__sys_readlink", .func = readlinkFn, .arity = 1 };
    ftruncate_n = .{ .name = "__sys_ftruncate", .func = ftruncateFn, .arity = 2 };
    umask_n = .{ .name = "__sys_umask", .func = umaskFn, .arity = 1 };
    nanosleep_n = .{ .name = "__sys_nanosleep", .func = nanosleepFn, .arity = 2 };
    fcntl_n = .{ .name = "__sys_fcntl", .func = fcntlFn, .arity = -1 };

    try vm.defineGlobal("__syscall", .{ .native = &call_n });
    try vm.defineGlobal("__sys_nr", .{ .native = &nr_n });
    try vm.defineGlobal("__sys_isError", .{ .native = &is_err_n });
    try vm.defineGlobal("__sys_errno", .{ .native = &errno_n });
    try vm.defineGlobal("__sys_errName", .{ .native = &err_name_n });
    try vm.defineGlobal("__sys_read", .{ .native = &read_n });
    try vm.defineGlobal("__sys_write", .{ .native = &write_n });
    try vm.defineGlobal("__sys_writeAll", .{ .native = &write_all_n });
    try vm.defineGlobal("__sys_open", .{ .native = &open_n });
    try vm.defineGlobal("__sys_close", .{ .native = &close_n });
    try vm.defineGlobal("__sys_lseek", .{ .native = &lseek_n });
    try vm.defineGlobal("__sys_fsync", .{ .native = &fsync_n });
    try vm.defineGlobal("__sys_pipe", .{ .native = &pipe_n });
    try vm.defineGlobal("__sys_dup", .{ .native = &dup_n });
    try vm.defineGlobal("__sys_dup2", .{ .native = &dup2_n });
    try vm.defineGlobal("__sys_getpid", .{ .native = &getpid_n });
    try vm.defineGlobal("__sys_getppid", .{ .native = &getppid_n });
    try vm.defineGlobal("__sys_getuid", .{ .native = &getuid_n });
    try vm.defineGlobal("__sys_geteuid", .{ .native = &geteuid_n });
    try vm.defineGlobal("__sys_getgid", .{ .native = &getgid_n });
    try vm.defineGlobal("__sys_getegid", .{ .native = &getegid_n });
    try vm.defineGlobal("__sys_kill", .{ .native = &kill_n });
    try vm.defineGlobal("__sys_chdir", .{ .native = &chdir_n });
    try vm.defineGlobal("__sys_getcwd", .{ .native = &getcwd_n });
    try vm.defineGlobal("__sys_unlink", .{ .native = &unlink_n });
    try vm.defineGlobal("__sys_rename", .{ .native = &rename_n });
    try vm.defineGlobal("__sys_mkdir", .{ .native = &mkdir_n });
    try vm.defineGlobal("__sys_rmdir", .{ .native = &rmdir_n });
    try vm.defineGlobal("__sys_access", .{ .native = &access_n });
    try vm.defineGlobal("__sys_chmod", .{ .native = &chmod_n });
    try vm.defineGlobal("__sys_symlink", .{ .native = &symlink_n });
    try vm.defineGlobal("__sys_readlink", .{ .native = &readlink_n });
    try vm.defineGlobal("__sys_ftruncate", .{ .native = &ftruncate_n });
    try vm.defineGlobal("__sys_umask", .{ .native = &umask_n });
    try vm.defineGlobal("__sys_nanosleep", .{ .native = &nanosleep_n });
    try vm.defineGlobal("__sys_fcntl", .{ .native = &fcntl_n });

    // Arch-correct SYS_* numbers (Linux only).
    try putSys(vm, "read");
    try putSys(vm, "write");
    try putSys(vm, "open");
    try putSys(vm, "openat");
    try putSys(vm, "close");
    try putSys(vm, "lseek");
    try putSys(vm, "mmap");
    try putSys(vm, "mprotect");
    try putSys(vm, "munmap");
    try putSys(vm, "brk");
    try putSys(vm, "ioctl");
    try putSys(vm, "pread64");
    try putSys(vm, "pwrite64");
    try putSys(vm, "readv");
    try putSys(vm, "writev");
    try putSys(vm, "access");
    try putSys(vm, "pipe");
    try putSys(vm, "dup");
    try putSys(vm, "dup2");
    try putSys(vm, "nanosleep");
    try putSys(vm, "getpid");
    try putSys(vm, "socket");
    try putSys(vm, "connect");
    try putSys(vm, "accept");
    try putSys(vm, "sendto");
    try putSys(vm, "recvfrom");
    try putSys(vm, "bind");
    try putSys(vm, "listen");
    try putSys(vm, "clone");
    try putSys(vm, "fork");
    try putSys(vm, "execve");
    try putSys(vm, "exit");
    try putSys(vm, "wait4");
    try putSys(vm, "kill");
    try putSys(vm, "fcntl");
    try putSys(vm, "fsync");
    try putSys(vm, "fdatasync");
    try putSys(vm, "truncate");
    try putSys(vm, "ftruncate");
    try putSys(vm, "getcwd");
    try putSys(vm, "chdir");
    try putSys(vm, "rename");
    try putSys(vm, "mkdir");
    try putSys(vm, "rmdir");
    try putSys(vm, "unlink");
    try putSys(vm, "symlink");
    try putSys(vm, "readlink");
    try putSys(vm, "chmod");
    try putSys(vm, "umask");
    try putSys(vm, "getuid");
    try putSys(vm, "getgid");
    try putSys(vm, "geteuid");
    try putSys(vm, "getegid");
    try putSys(vm, "getppid");
    try putSys(vm, "clock_gettime");
    try putSys(vm, "stat");
    try putSys(vm, "fstat");
    try putSys(vm, "lstat");

    // Portable flag / fd constants (Linux values; match posix).
    try putInt(vm, "__O_RDONLY", @intCast(@as(u32, @bitCast(std.posix.O{ .ACCMODE = .RDONLY }))));
    try putInt(vm, "__O_WRONLY", @intCast(@as(u32, @bitCast(std.posix.O{ .ACCMODE = .WRONLY }))));
    try putInt(vm, "__O_RDWR", @intCast(@as(u32, @bitCast(std.posix.O{ .ACCMODE = .RDWR }))));
    try putInt(vm, "__O_CREAT", @intCast(@as(u32, @bitCast(std.posix.O{ .CREAT = true }))));
    try putInt(vm, "__O_EXCL", @intCast(@as(u32, @bitCast(std.posix.O{ .EXCL = true }))));
    try putInt(vm, "__O_TRUNC", @intCast(@as(u32, @bitCast(std.posix.O{ .TRUNC = true }))));
    try putInt(vm, "__O_APPEND", @intCast(@as(u32, @bitCast(std.posix.O{ .APPEND = true }))));
    try putInt(vm, "__O_NONBLOCK", @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))));
    try putInt(vm, "__O_DIRECTORY", @intCast(@as(u32, @bitCast(std.posix.O{ .DIRECTORY = true }))));
    try putInt(vm, "__O_CLOEXEC", @intCast(@as(u32, @bitCast(std.posix.O{ .CLOEXEC = true }))));

    try putInt(vm, "__SEEK_SET", std.posix.SEEK.SET);
    try putInt(vm, "__SEEK_CUR", std.posix.SEEK.CUR);
    try putInt(vm, "__SEEK_END", std.posix.SEEK.END);

    try putInt(vm, "__STDIN_FILENO", std.posix.STDIN_FILENO);
    try putInt(vm, "__STDOUT_FILENO", std.posix.STDOUT_FILENO);
    try putInt(vm, "__STDERR_FILENO", std.posix.STDERR_FILENO);

    try putInt(vm, "__F_OK", @intCast(std.posix.F_OK));
    try putInt(vm, "__R_OK", @intCast(std.posix.R_OK));
    try putInt(vm, "__W_OK", @intCast(std.posix.W_OK));
    try putInt(vm, "__X_OK", @intCast(std.posix.X_OK));

    try putInt(vm, "__AT_FDCWD", std.posix.AT.FDCWD);

    try putInt(vm, "__S_IRWXU", 0o700);
    try putInt(vm, "__S_IRUSR", 0o400);
    try putInt(vm, "__S_IWUSR", 0o200);
    try putInt(vm, "__S_IXUSR", 0o100);
    try putInt(vm, "__S_IRWXG", 0o070);
    try putInt(vm, "__S_IRGRP", 0o040);
    try putInt(vm, "__S_IWGRP", 0o020);
    try putInt(vm, "__S_IXGRP", 0o010);
    try putInt(vm, "__S_IRWXO", 0o007);
    try putInt(vm, "__S_IROTH", 0o004);
    try putInt(vm, "__S_IWOTH", 0o002);
    try putInt(vm, "__S_IXOTH", 0o001);

    try putInt(vm, "__SIGTERM", 15);
    try putInt(vm, "__SIGKILL", 9);
    try putInt(vm, "__SIGINT", 2);
    try putInt(vm, "__SIGHUP", 1);
    try putInt(vm, "__SIGUSR1", 10);
    try putInt(vm, "__SIGUSR2", 12);

    try putInt(vm, "__F_GETFD", std.posix.F.GETFD);
    try putInt(vm, "__F_SETFD", std.posix.F.SETFD);
    try putInt(vm, "__F_GETFL", std.posix.F.GETFL);
    try putInt(vm, "__F_SETFL", std.posix.F.SETFL);
    try putInt(vm, "__FD_CLOEXEC", 1);
}
