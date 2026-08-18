//! Native filesystem functions backing `std/fs.lls` + `std/io.lls` (mirrors
//! `src/vm/builtins/io.zig`). Native strings are C strings; string results are
//! copied into the runtime string heap (see `util.zig`).
//!
//! Error convention (matches the LLVM backend's `@isError` lowering):
//!   - i64-returning natives return `minInt(i64)` on failure,
//!   - pointer-returning natives return `null` on failure.
//! The full error-code/payload ABI (`error(name, path)` with `.code` /
//! `.payload`) is carried by the pure-LLS wrapper path in `std/fs.lls`
//! (`mapIo`), which routes through the syscall natives instead.

const std = @import("std");
const util = @import("util.zig");

const cstr = util.cstr;
const dupBytes = util.dupBytes;
const strAlloc = util.strAlloc;
const countPrefixedStrings = util.countPrefixedStrings;

const ERR: i64 = std.math.minInt(i64);

/// Error-region pointer for a string-returning native failure (so `@isError`
/// on the result is true — the error value is an `ErrCode` address in the
/// error region, see `util.zig`).
fn errPtr(err: anyerror, path: []const u8) [*:0]u8 {
    return @ptrFromInt(util.errNewAddr(util.dupBytes(util.ioErrorCode(err)), @intFromPtr(util.dupBytes(path))));
}

// ────────────────────────────── read / write ──────────────────────────────

export fn __readFile(path: [*:0]const u8) ?[*:0]u8 {
    const content = std.fs.cwd().readFileAlloc(strAlloc(), cstr(path), 16 * 1024 * 1024) catch |err| return errPtr(err, cstr(path));
    defer strAlloc().free(content);
    return dupBytes(content);
}

export fn __readLine(fd_in: i64) ?[*:0]u8 {
    const fd: std.posix.fd_t = @intCast(fd_in);
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| return errPtr(err, "");
    if (n == 0) return null;
    var str = buf[0..n];
    if (std.mem.indexOfScalar(u8, str, '\n')) |nl| str = str[0..nl];
    if (std.mem.endsWith(u8, str, "\r")) str = str[0 .. str.len - 1];
    return dupBytes(str);
}

export fn __writeFile(path: [*:0]const u8, content: [*:0]const u8) i64 {
    const file = std.fs.cwd().createFile(cstr(path), .{}) catch return ERR;
    defer file.close();
    file.writeAll(cstr(content)) catch return ERR;
    return 0;
}

export fn __appendFile(path: [*:0]const u8, content: [*:0]const u8) i64 {
    const file = std.fs.cwd().createFile(cstr(path), .{ .truncate = false }) catch return ERR;
    defer file.close();
    file.seekFromEnd(0) catch return ERR;
    file.writeAll(cstr(content)) catch return ERR;
    return 0;
}

export fn __deleteFile(path: [*:0]const u8) i64 {
    std.fs.cwd().deleteFile(cstr(path)) catch return ERR;
    return 0;
}

// ─────────────────────────────── queries ──────────────────────────────────

export fn __exists(path: [*:0]const u8) bool {
    std.fs.cwd().access(cstr(path), .{}) catch return false;
    return true;
}

export fn __mkdir(path: [*:0]const u8) i64 {
    std.fs.cwd().makeDir(cstr(path)) catch return ERR;
    return 0;
}

export fn __mkdirAll(path: [*:0]const u8) i64 {
    std.fs.cwd().makePath(cstr(path)) catch return ERR;
    return 0;
}

export fn __readDir(path: [*:0]const u8) ?[*]const u8 {
    var dir = std.fs.cwd().openDir(cstr(path), .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    var names: std.ArrayList([*:0]const u8) = .empty;
    defer names.deinit(strAlloc());
    while (it.next() catch return null) |entry| {
        names.append(strAlloc(), dupBytes(entry.name)) catch return null;
    }
    return countPrefixedStrings(names.items);
}

/// `[size, mtime_ms, atime_ms, ctime_ms, kind]` as a count-prefixed f64 array
/// (kind: 0=unknown, 1=file, 2=directory, 3=symlink) — matches the VM. The
/// count slot holds the i64 count bitcast to f64 (same as the backend's
/// rest-arg packing), so `arr[-1]` reads back a sane count.
export fn __stat(path: [*:0]const u8) ?[*]const u8 {
    const stat = std.fs.cwd().statFile(cstr(path)) catch return null;
    const alloc = strAlloc();
    const slots = alloc.alloc(f64, 6) catch return null;
    slots[0] = @bitCast(@as(i64, 5)); // count
    slots[1] = @floatFromInt(stat.size);
    slots[2] = @floatFromInt(@divTrunc(stat.mtime, 1000000));
    slots[3] = @floatFromInt(@divTrunc(stat.atime, 1000000));
    slots[4] = @floatFromInt(@divTrunc(stat.ctime, 1000000));
    const kind: f64 = switch (stat.kind) {
        .file => 1.0,
        .directory => 2.0,
        .sym_link => 3.0,
        else => 0.0,
    };
    slots[5] = kind;
    const raw: [*]const u8 = @ptrCast(slots.ptr);
    return raw + @sizeOf(f64);
}

// ─────────────────────────────── rename/move ──────────────────────────────

export fn __rename(old_path: [*:0]const u8, new_path: [*:0]const u8) i64 {
    std.fs.cwd().rename(cstr(old_path), cstr(new_path)) catch return ERR;
    return 0;
}

export fn __copyFile(src: [*:0]const u8, dst: [*:0]const u8) i64 {
    std.fs.cwd().copyFile(cstr(src), std.fs.cwd(), cstr(dst), .{}) catch return ERR;
    return 0;
}

// ─────────────────────────────── links / paths ────────────────────────────

export fn __symlink(target: [*:0]const u8, path: [*:0]const u8) i64 {
    std.fs.cwd().symLink(cstr(target), cstr(path), .{}) catch return ERR;
    return 0;
}

export fn __readlink(path: [*:0]const u8) ?[*:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = std.fs.cwd().readLink(cstr(path), &buf) catch |err| return errPtr(err, cstr(path));
    return dupBytes(link);
}

export fn __realpath(path: [*:0]const u8) ?[*:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.fs.cwd().realpath(cstr(path), &buf) catch |err| return errPtr(err, cstr(path));
    return dupBytes(real);
}

export fn __chmod(path: [*:0]const u8, mode: i64) i64 {
    std.posix.fchmodat(std.posix.AT.FDCWD, cstr(path), @intCast(mode), 0) catch return ERR;
    return 0;
}
