//! Shared helpers for the native `__`-function runtime (mirrors the VM's
//! `src/vm/builtins/util.zig`).
//!
//! Native strings are NUL-terminated `i8*` (C strings). String results are
//! copied into a global bump arena — VM parity: native results live until
//! process exit, like the VM's immortal byte heap. Native arrays (rest args,
//! `__split` results) are count-prefixed: `arr` points at element 0 and
//! `arr[-1]` (pointer-width, bitcast) holds the element count — the same
//! layout the LLVM backend's rest-arg packing and `__arrayLen` use.

const std = @import("std");

var heap: ?std.heap.ArenaAllocator = null;

pub fn strAlloc() std.mem.Allocator {
    if (heap == null) heap = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return heap.?.allocator();
}

pub fn dupBytes(bytes: []const u8) [*:0]u8 {
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, bytes.len, 0) catch @panic("native OOM");
    @memcpy(buf[0..bytes.len], bytes);
    return buf.ptr;
}

pub fn cstr(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

/// Build a count-prefixed array of `[*:0]const u8` items (`arr[-1]` = count).
pub fn countPrefixedStrings(items: []const [*:0]const u8) [*]const u8 {
    const alloc = strAlloc();
    const slots = alloc.alloc(usize, items.len + 1) catch @panic("native OOM");
    slots[0] = items.len;
    for (items, 0..) |it, i| slots[i + 1] = @intFromPtr(it);
    const raw: [*]const u8 = @ptrCast(slots.ptr);
    return raw + @sizeOf(usize);
}

pub fn arrayCount(arr: [*]align(8) const u8) usize {
    const slots: [*]const usize = @ptrCast(arr);
    // `arr[-1]` — the count slot lives immediately before element 0 (the
    // index wraps to the preceding slot).
    return slots[~@as(usize, 0)];
}

// ─────────────────────────── error values ─────────────────────────────────
//
// Error values are tagged so `@isError` / `.code` / `.payload` (lowered to
// `__err_is` / `__err_code` / `__err_payload`) can recover the code + payload
// while a single scalar slot still carries either a valid result or an error:
//
//   - i64-typed errors (syscall natives, `error(name, payload)` literals)
//     are the NEGATED address of an `ErrCode` record (`-ptr`), so the value
//     is negative — the same spirit as the kernel's -errno convention.
//   - pointer-typed errors (string-returning natives like `__fromCharCode`)
//     are the raw `ErrCode` address, detected via the error-region bounds
//     check (the record lives in a dedicated 1 MiB static arena).
//
// `__err_is` also treats plain negative values (raw `-errno` syscall results
// and the math natives' `minInt(i64)` sentinel) as errors, matching the VM.

const ErrCode = struct { code: [*:0]const u8, payload: u64 };

/// Map common filesystem Zig errors to stable LLTS error codes (mirrors the
/// VM's `src/vm/builtins/util.zig::ioErrorCode`).
pub fn ioErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "FileNotFound",
        error.AccessDenied => "AccessDenied",
        error.IsDir => "IsDir",
        error.NotDir => "NotDir",
        error.PathAlreadyExists => "PathAlreadyExists",
        error.FileBusy => "FileBusy",
        error.SharingViolation => "SharingViolation",
        else => "IoError",
    };
}

var err_buf: [1 << 20]u8 align(16) = undefined;
var err_bump: usize = 0;

fn errStart() usize {
    return @intFromPtr(&err_buf);
}

fn errEnd() usize {
    return errStart() + err_buf.len;
}

fn errAlloc() *ErrCode {
    const align_n: usize = 16;
    const start = errStart();
    const off = (err_bump + align_n - 1) & ~(align_n - 1);
    err_bump = off + @sizeOf(ErrCode);
    const rec: *ErrCode = @ptrFromInt(start + off);
    rec.* = .{ .code = undefined, .payload = 0 };
    return rec;
}

/// Allocate an error record; returns the record address (for pointer-typed
/// error returns) and the negated address (for i64-typed error returns).
pub fn errNewAddr(code: [*:0]const u8, payload: u64) usize {
    const rec = errAlloc();
    rec.code = code;
    rec.payload = payload;
    return @intFromPtr(rec);
}

pub fn errNew(code: [*:0]const u8, payload: u64) i64 {
    return -@as(i64, @bitCast(@as(u64, @intCast(errNewAddr(code, payload)))));
}

export fn __err_new(code: [*:0]const u8, payload: u64) i64 {
    return errNew(code, payload);
}

pub export fn __err_is(v: i64) bool {
    if (v < 0) return true; // negated error ptr, raw -errno rc, or minInt sentinel
    const p: u64 = @bitCast(v);
    return p >= errStart() and p < errEnd();
}

fn errPtr(v: i64) usize {
    if (v < 0) {
        if (v == std.math.minInt(i64)) return 0;
        const nv: u64 = 0 -% @as(u64, @bitCast(v));
        return @intCast(nv);
    }
    const p: u64 = @bitCast(v);
    if (p >= errStart() and p < errEnd()) return @intCast(p);
    return 0;
}

pub export fn __err_code(v: i64) [*:0]const u8 {
    const p = errPtr(v);
    if (p == 0) return dupBytes("");
    return (@as(*ErrCode, @ptrFromInt(p))).code;
}

pub export fn __err_payload(v: i64) [*:0]u8 {
    const p = errPtr(v);
    if (p == 0) return dupBytes("");
    const payload = (@as(*ErrCode, @ptrFromInt(p))).payload;
    if (payload == 0) return dupBytes("");
    return @ptrFromInt(payload);
}
