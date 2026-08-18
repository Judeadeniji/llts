//! Low-level OS syscall natives backing `std/syscall.lls` (mirrors
//! `src/vm/builtins/syscall.zig`).
//!
//! Error convention (see `util.zig`): i64-typed natives return either a valid
//! non-negative result or a negated error pointer (`-ErrCode` address); the
//! string-returning ones return the raw `ErrCode` address (error region). The
//! raw `__syscall` escape hatch returns the kernel rc (`-errno` on failure),
//! exactly like the VM. `__err_is` treats both negative values and error-region
//! pointers as errors, so `@isError` works uniformly.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const buffer = @import("buffer.zig");

const linux = std.os.linux;
const cstr = util.cstr;
const dupBytes = util.dupBytes;

fn errI(err: anyerror) i64 {
    return util.errNew(dupBytes("SyscallError"), @intFromPtr(dupBytes(@errorName(err))));
}

fn errPtr(err: anyerror) [*:0]u8 {
    return @ptrFromInt(util.errNewAddr(dupBytes("SyscallError"), @intFromPtr(dupBytes(@errorName(err)))));
}

fn rcToInt(rc: usize) i64 {
    return @bitCast(@as(isize, @bitCast(rc)));
}

fn fdT(v: i64) std.posix.fd_t {
    return @intCast(v);
}

// ─────────────────────────── raw escape hatch ─────────────────────────────

/// `__syscall(nr, args)` — `args` is a count-prefixed i64 array (`arr[-1]` =
/// count), the same layout the backend's rest-arg packing uses.
export fn __syscall(nr: i64, args: i64) i64 {
    if (builtin.os.tag != .linux) return 0;
    const arr: [*]align(8) const u8 = @ptrFromInt(@as(usize, @bitCast(args)));
    const count = util.arrayCount(arr);
    const slots: [*]const i64 = @ptrCast(arr);
    var a: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
    const n = @min(count, 6);
    for (0..n) |i| a[i] = @intCast(slots[i]);
    const sys: linux.SYS = @enumFromInt(@as(usize, @intCast(nr)));
    const rc = switch (n) {
        0 => linux.syscall0(sys),
        1 => linux.syscall1(sys, a[0]),
        2 => linux.syscall2(sys, a[0], a[1]),
        3 => linux.syscall3(sys, a[0], a[1], a[2]),
        4 => linux.syscall4(sys, a[0], a[1], a[2], a[3]),
        5 => linux.syscall5(sys, a[0], a[1], a[2], a[3], a[4]),
        else => linux.syscall6(sys, a[0], a[1], a[2], a[3], a[4], a[5]),
    };
    return rcToInt(rc);
}

export fn __sys_nr(name: [*:0]const u8) i64 {
    if (builtin.os.tag != .linux) return 0;
    inline for (@typeInfo(linux.SYS).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, cstr(name))) return @intCast(f.value);
    }
    return util.errNew(dupBytes("SyscallError"), @intFromPtr(dupBytes("UnknownSyscall")));
}

export fn __sys_isError(rc: i64) bool {
    const r: usize = @bitCast(rc);
    return linux.E.init(r) != .SUCCESS;
}

export fn __sys_errno(rc: i64) i64 {
    const r: usize = @bitCast(rc);
    return @intFromEnum(linux.E.init(r));
}

export fn __sys_errName(rc: i64) [*:0]u8 {
    const r: usize = @bitCast(rc);
    const e = linux.E.init(r);
    if (e == .SUCCESS) return dupBytes("");
    return dupBytes(@tagName(e));
}

// ─────────────────────────── typed wrappers ───────────────────────────────

export fn __sys_read(fd_in: i64, buf_handle: i64) i64 {
    const b = buffer.fromHandle(buf_handle);
    const n = std.posix.read(fdT(fd_in), b.data[0..b.len]) catch |err| return errI(err);
    return @intCast(n);
}

export fn __sys_write(fd_in: i64, data: i64) i64 {
    const fd = fdT(fd_in);
    const p: usize = @bitCast(data);
    const bytes = if (buffer.inRegion(p))
        buffer.fromHandle(data).data[0 .. buffer.fromHandle(data).len]
    else
        std.mem.span(@as([*:0]const u8, @ptrFromInt(p)));
    const n = std.posix.write(fd, bytes) catch |err| return errI(err);
    return @intCast(n);
}

export fn __sys_writeAll(fd_in: i64, data: i64) i64 {
    const fd = fdT(fd_in);
    const p: usize = @bitCast(data);
    const bytes = if (buffer.inRegion(p))
        buffer.fromHandle(data).data[0 .. buffer.fromHandle(data).len]
    else
        std.mem.span(@as([*:0]const u8, @ptrFromInt(p)));
    var remaining = bytes;
    var total: i64 = 0;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch |err| return errI(err);
        if (n == 0) return util.errNew(dupBytes("SyscallError"), @intFromPtr(dupBytes("ShortWrite")));
        remaining = remaining[n..];
        total += @intCast(n);
    }
    return total;
}

/// `open(path, flags, mode)` — mode defaults to 0 (the backend zero-pads the
/// trailing variadic arg), matching the VM.
export fn __sys_open(path: [*:0]const u8, flags_i: i64, mode_in: i64) i64 {
    const flags: std.posix.O = @bitCast(@as(u32, @intCast(flags_i)));
    const mode: std.posix.mode_t = @intCast(mode_in);
    const fd = std.posix.open(cstr(path), flags, mode) catch |err| return errI(err);
    return @intCast(fd);
}

export fn __sys_close(fd_in: i64) i64 {
    std.posix.close(fdT(fd_in));
    return 0;
}

export fn __sys_lseek(fd_in: i64, offset: i64, whence_in: i64) i64 {
    const fd = fdT(fd_in);
    const whence: i32 = @intCast(whence_in);
    switch (whence) {
        std.posix.SEEK.SET => std.posix.lseek_SET(fd, @intCast(offset)) catch |err| return errI(err),
        std.posix.SEEK.CUR => std.posix.lseek_CUR(fd, offset) catch |err| return errI(err),
        std.posix.SEEK.END => std.posix.lseek_END(fd, offset) catch |err| return errI(err),
        else => return util.errNew(dupBytes("SyscallError"), @intFromPtr(dupBytes("INVAL"))),
    }
    const pos = std.posix.lseek_CUR_get(fd) catch |err| return errI(err);
    return @intCast(pos);
}

export fn __sys_fsync(fd_in: i64) i64 {
    std.posix.fsync(fdT(fd_in)) catch |err| return errI(err);
    return 0;
}

export fn __sys_pipe() i64 {
    const fds = std.posix.pipe() catch |err| return errI(err);
    const alloc = util.strAlloc();
    const slots = alloc.alloc(i64, 3) catch return errI(error.OutOfMemory);
    slots[0] = 2;
    slots[1] = @intCast(fds[0]);
    slots[2] = @intCast(fds[1]);
    return @intCast(@intFromPtr(slots.ptr + 1));
}

export fn __sys_dup(fd_in: i64) i64 {
    const new_fd = std.posix.dup(fdT(fd_in)) catch |err| return errI(err);
    return @intCast(new_fd);
}

export fn __sys_dup2(old_fd: i64, new_fd: i64) i64 {
    std.posix.dup2(fdT(old_fd), fdT(new_fd)) catch |err| return errI(err);
    return 0;
}

export fn __sys_getpid() i64 {
    return @intCast(std.os.linux.getpid());
}

export fn __sys_getppid() i64 {
    if (builtin.os.tag != .linux) return 0;
    return rcToInt(linux.syscall0(.getppid));
}

export fn __sys_getuid() i64 {
    return @intCast(std.posix.getuid());
}

export fn __sys_geteuid() i64 {
    return @intCast(std.posix.geteuid());
}

export fn __sys_getgid() i64 {
    if (builtin.os.tag != .linux) return 0;
    return rcToInt(linux.syscall0(.getgid));
}

export fn __sys_getegid() i64 {
    if (builtin.os.tag != .linux) return 0;
    return rcToInt(linux.syscall0(.getegid));
}

export fn __sys_kill(pid_in: i64, sig_in: i64) i64 {
    std.posix.kill(@intCast(pid_in), @intCast(sig_in)) catch |err| return errI(err);
    return 0;
}

export fn __sys_chdir(path: [*:0]const u8) i64 {
    std.posix.chdir(cstr(path)) catch |err| return errI(err);
    return 0;
}

export fn __sys_getcwd() ?[*:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch |err| return errPtr(err);
    return dupBytes(cwd);
}

export fn __sys_unlink(path: [*:0]const u8) i64 {
    std.posix.unlink(cstr(path)) catch |err| return errI(err);
    return 0;
}

export fn __sys_rename(old_path: [*:0]const u8, new_path: [*:0]const u8) i64 {
    std.posix.rename(cstr(old_path), cstr(new_path)) catch |err| return errI(err);
    return 0;
}

/// `mkdir(path, mode)` — mode defaults to 0o755 when the caller omits it
/// (the VM's convention for the variadic arg).
export fn __sys_mkdir(path: [*:0]const u8, mode_in: i64) i64 {
    var mode: std.posix.mode_t = @intCast(mode_in);
    if (mode == 0) mode = 0o755;
    std.posix.mkdir(cstr(path), mode) catch |err| return errI(err);
    return 0;
}

export fn __sys_rmdir(path: [*:0]const u8) i64 {
    std.posix.rmdir(cstr(path)) catch |err| return errI(err);
    return 0;
}

/// `access(path, mode)` — mode defaults to F_OK (0) when omitted.
export fn __sys_access(path: [*:0]const u8, mode_in: i64) i64 {
    const mode: u32 = @intCast(mode_in);
    std.posix.access(cstr(path), mode) catch |err| return errI(err);
    return 0;
}

export fn __sys_chmod(path: [*:0]const u8, mode_in: i64) i64 {
    const mode: std.posix.mode_t = @intCast(mode_in);
    std.posix.fchmodat(std.posix.AT.FDCWD, cstr(path), mode, 0) catch |err| return errI(err);
    return 0;
}

export fn __sys_symlink(target: [*:0]const u8, path: [*:0]const u8) i64 {
    std.posix.symlink(cstr(target), cstr(path)) catch |err| return errI(err);
    return 0;
}

export fn __sys_readlink(path: [*:0]const u8) ?[*:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = std.posix.readlink(cstr(path), &buf) catch |err| return errPtr(err);
    return dupBytes(out);
}

export fn __sys_ftruncate(fd_in: i64, len_in: i64) i64 {
    std.posix.ftruncate(fdT(fd_in), @intCast(len_in)) catch |err| return errI(err);
    return 0;
}

export fn __sys_umask(mask_in: i64) i64 {
    const old = std.c.umask(@intCast(mask_in));
    return @intCast(old);
}

export fn __sys_nanosleep(sec: i64, nsec: i64) i64 {
    std.posix.nanosleep(@intCast(sec), @intCast(nsec));
    return 0;
}

/// `fcntl(fd, cmd, arg)` — arg defaults to 0 when omitted.
export fn __sys_fcntl(fd_in: i64, cmd_in: i64, arg_in: i64) i64 {
    const rc = std.posix.fcntl(fdT(fd_in), @intCast(cmd_in), @intCast(arg_in)) catch |err| return errI(err);
    return @intCast(rc);
}

// ───────────────────────────── SYS_* numbers ──────────────────────────────

fn sysNr(comptime name: []const u8) i64 {
    return @intFromEnum(@field(linux.SYS, name));
}

export fn __SYS_read() i64 {
    return sysNr("read");
}
export fn __SYS_write() i64 {
    return sysNr("write");
}
export fn __SYS_open() i64 {
    return sysNr("open");
}
export fn __SYS_openat() i64 {
    return sysNr("openat");
}
export fn __SYS_close() i64 {
    return sysNr("close");
}
export fn __SYS_lseek() i64 {
    return sysNr("lseek");
}
export fn __SYS_mmap() i64 {
    return sysNr("mmap");
}
export fn __SYS_mprotect() i64 {
    return sysNr("mprotect");
}
export fn __SYS_munmap() i64 {
    return sysNr("munmap");
}
export fn __SYS_brk() i64 {
    return sysNr("brk");
}
export fn __SYS_ioctl() i64 {
    return sysNr("ioctl");
}
export fn __SYS_access() i64 {
    return sysNr("access");
}
export fn __SYS_pipe() i64 {
    return sysNr("pipe");
}
export fn __SYS_dup() i64 {
    return sysNr("dup");
}
export fn __SYS_dup2() i64 {
    return sysNr("dup2");
}
export fn __SYS_nanosleep() i64 {
    return sysNr("nanosleep");
}
export fn __SYS_getpid() i64 {
    return sysNr("getpid");
}
export fn __SYS_socket() i64 {
    return sysNr("socket");
}
export fn __SYS_connect() i64 {
    return sysNr("connect");
}
export fn __SYS_accept() i64 {
    return sysNr("accept");
}
export fn __SYS_bind() i64 {
    return sysNr("bind");
}
export fn __SYS_listen() i64 {
    return sysNr("listen");
}
export fn __SYS_clone() i64 {
    return sysNr("clone");
}
export fn __SYS_fork() i64 {
    return sysNr("fork");
}
export fn __SYS_execve() i64 {
    return sysNr("execve");
}
export fn __SYS_exit() i64 {
    return sysNr("exit");
}
export fn __SYS_wait4() i64 {
    return sysNr("wait4");
}
export fn __SYS_kill() i64 {
    return sysNr("kill");
}
export fn __SYS_fcntl() i64 {
    return sysNr("fcntl");
}
export fn __SYS_fsync() i64 {
    return sysNr("fsync");
}
export fn __SYS_ftruncate() i64 {
    return sysNr("ftruncate");
}
export fn __SYS_getcwd() i64 {
    return sysNr("getcwd");
}
export fn __SYS_chdir() i64 {
    return sysNr("chdir");
}
export fn __SYS_rename() i64 {
    return sysNr("rename");
}
export fn __SYS_mkdir() i64 {
    return sysNr("mkdir");
}
export fn __SYS_rmdir() i64 {
    return sysNr("rmdir");
}
export fn __SYS_unlink() i64 {
    return sysNr("unlink");
}
export fn __SYS_symlink() i64 {
    return sysNr("symlink");
}
export fn __SYS_readlink() i64 {
    return sysNr("readlink");
}
export fn __SYS_chmod() i64 {
    return sysNr("chmod");
}
export fn __SYS_umask() i64 {
    return sysNr("umask");
}
export fn __SYS_getuid() i64 {
    return sysNr("getuid");
}
export fn __SYS_getgid() i64 {
    return sysNr("getgid");
}
export fn __SYS_geteuid() i64 {
    return sysNr("geteuid");
}
export fn __SYS_getegid() i64 {
    return sysNr("getegid");
}
export fn __SYS_getppid() i64 {
    return sysNr("getppid");
}
export fn __SYS_clock_gettime() i64 {
    return sysNr("clock_gettime");
}

// ─────────────────────────── open flags / misc ────────────────────────────

fn oFlags(comptime o: std.posix.O) i64 {
    return @intCast(@as(u32, @bitCast(o)));
}

export fn __O_RDONLY() i64 {
    return oFlags(.{ .ACCMODE = .RDONLY });
}
export fn __O_WRONLY() i64 {
    return oFlags(.{ .ACCMODE = .WRONLY });
}
export fn __O_RDWR() i64 {
    return oFlags(.{ .ACCMODE = .RDWR });
}
export fn __O_CREAT() i64 {
    return oFlags(.{ .CREAT = true });
}
export fn __O_EXCL() i64 {
    return oFlags(.{ .EXCL = true });
}
export fn __O_TRUNC() i64 {
    return oFlags(.{ .TRUNC = true });
}
export fn __O_APPEND() i64 {
    return oFlags(.{ .APPEND = true });
}
export fn __O_NONBLOCK() i64 {
    return oFlags(.{ .NONBLOCK = true });
}
export fn __O_DIRECTORY() i64 {
    return oFlags(.{ .DIRECTORY = true });
}
export fn __O_CLOEXEC() i64 {
    return oFlags(.{ .CLOEXEC = true });
}

export fn __SEEK_SET() i64 {
    return std.posix.SEEK.SET;
}
export fn __SEEK_CUR() i64 {
    return std.posix.SEEK.CUR;
}
export fn __SEEK_END() i64 {
    return std.posix.SEEK.END;
}

export fn __STDIN_FILENO() i64 {
    return std.posix.STDIN_FILENO;
}
export fn __STDOUT_FILENO() i64 {
    return std.posix.STDOUT_FILENO;
}
export fn __STDERR_FILENO() i64 {
    return std.posix.STDERR_FILENO;
}

export fn __F_OK() i64 {
    return @intCast(std.posix.F_OK);
}
export fn __R_OK() i64 {
    return @intCast(std.posix.R_OK);
}
export fn __W_OK() i64 {
    return @intCast(std.posix.W_OK);
}
export fn __X_OK() i64 {
    return @intCast(std.posix.X_OK);
}

export fn __AT_FDCWD() i64 {
    return std.posix.AT.FDCWD;
}

export fn __S_IRWXU() i64 {
    return 0o700;
}
export fn __S_IRUSR() i64 {
    return 0o400;
}
export fn __S_IWUSR() i64 {
    return 0o200;
}
export fn __S_IXUSR() i64 {
    return 0o100;
}
export fn __S_IRWXG() i64 {
    return 0o070;
}
export fn __S_IRGRP() i64 {
    return 0o040;
}
export fn __S_IWGRP() i64 {
    return 0o020;
}
export fn __S_IXGRP() i64 {
    return 0o010;
}
export fn __S_IRWXO() i64 {
    return 0o007;
}
export fn __S_IROTH() i64 {
    return 0o004;
}
export fn __S_IWOTH() i64 {
    return 0o002;
}
export fn __S_IXOTH() i64 {
    return 0o001;
}

export fn __SIGTERM() i64 {
    return 15;
}
export fn __SIGKILL() i64 {
    return 9;
}
export fn __SIGINT() i64 {
    return 2;
}
export fn __SIGHUP() i64 {
    return 1;
}
export fn __SIGUSR1() i64 {
    return 10;
}
export fn __SIGUSR2() i64 {
    return 12;
}

export fn __F_GETFD() i64 {
    return std.posix.F.GETFD;
}
export fn __F_SETFD() i64 {
    return std.posix.F.SETFD;
}
export fn __F_GETFL() i64 {
    return std.posix.F.GETFL;
}
export fn __F_SETFL() i64 {
    return std.posix.F.SETFL;
}
export fn __FD_CLOEXEC() i64 {
    return 1;
}
