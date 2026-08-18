//! Growable byte-buffer natives backing `std/buffer.lls` (mirrors
//! `src/vm/builtins/buffer.zig`).
//!
//! A buffer is an opaque `i64` handle pointing at a `Buffer` record allocated
//! from a dedicated static region — the region check is how `__sys_write`
//! distinguishes a buffer argument from a plain C string. The byte `data` is
//! heap-allocated and grows via realloc.

const std = @import("std");
const util = @import("util.zig");

const cstr = util.cstr;
const dupBytes = util.dupBytes;

const Buffer = struct { data: [*]u8, len: usize, cap: usize };

var buf_struct_region: [8192]u8 align(16) = undefined;
var buf_struct_bump: usize = 0;

fn regionStart() usize {
    return @intFromPtr(&buf_struct_region);
}

fn regionEnd() usize {
    return regionStart() + buf_struct_region.len;
}

/// Is `p` the address of a Buffer record (vs. a plain C string)?
pub fn inRegion(p: usize) bool {
    return p >= regionStart() and p < regionEnd();
}

fn newBuffer() *Buffer {
    const align_n: usize = 16;
    const off = (buf_struct_bump + align_n - 1) & ~(align_n - 1);
    buf_struct_bump = off + @sizeOf(Buffer);
    const b: *Buffer = @ptrFromInt(regionStart() + off);
    b.* = .{ .data = undefined, .len = 0, .cap = 0 };
    return b;
}

pub fn fromHandle(h: i64) *Buffer {
    return @ptrFromInt(@as(usize, @bitCast(h)));
}

fn grow(b: *Buffer, need: usize) void {
    if (need <= b.cap) return;
    var new_cap = if (b.cap == 0) @as(usize, 16) else b.cap;
    while (new_cap < need) new_cap *= 2;
    const data = std.heap.page_allocator.realloc(b.data[0..b.cap], new_cap) catch @panic("buffer OOM");
    b.data = data.ptr;
    b.cap = new_cap;
}

// ──────────────────────────────── natives ─────────────────────────────────

export fn __bufferAlloc(size_in: i64) i64 {
    if (size_in < 0) return 0; // VM throws IndexOutOfBounds; safe fallback
    const n: usize = @intCast(size_in);
    const b = newBuffer();
    const cap = @max(n, 1);
    b.data = (std.heap.page_allocator.alloc(u8, cap) catch return 0).ptr;
    b.len = n;
    b.cap = cap;
    @memset(b.data[0..n], 0);
    return @intCast(@intFromPtr(b));
}

export fn __bufferCreate() i64 {
    const b = newBuffer();
    b.data = (std.heap.page_allocator.alloc(u8, 16) catch return 0).ptr;
    b.len = 0;
    b.cap = 16;
    return @intCast(@intFromPtr(b));
}

export fn __bufferFromString(s: [*:0]const u8) i64 {
    const bytes = cstr(s);
    const b = newBuffer();
    const cap = @max(bytes.len, 1);
    b.data = (std.heap.page_allocator.alloc(u8, cap) catch return 0).ptr;
    @memcpy(b.data[0..bytes.len], bytes);
    b.len = bytes.len;
    b.cap = cap;
    return @intCast(@intFromPtr(b));
}

export fn __bufferWriteString(buf: i64, offset_in: i64, str: [*:0]const u8) i64 {
    const b = fromHandle(buf);
    const off: usize = @intCast(offset_in);
    const s = cstr(str);
    if (off > b.len or s.len > b.len - off) return -1; // OOB → error sentinel
    @memcpy(b.data[off .. off + s.len], s);
    return @intCast(s.len);
}

export fn __bufferAppendString(buf: i64, str: [*:0]const u8) i64 {
    const b = fromHandle(buf);
    const s = cstr(str);
    grow(b, b.len + s.len);
    @memcpy(b.data[b.len .. b.len + s.len], s);
    b.len += s.len;
    return @intCast(s.len);
}

export fn __bufferReadString(buf: i64, offset_in: i64, len_in: i64) [*:0]u8 {
    const b = fromHandle(buf);
    const off: usize = @intCast(offset_in);
    const n: usize = @intCast(len_in);
    if (n == 0) return dupBytes("");
    if (off > b.len or n > b.len - off) return dupBytes("");
    return dupBytes(b.data[off .. off + n]);
}

export fn __bufferLen(buf: i64) i64 {
    return @intCast(fromHandle(buf).len);
}

export fn __bufferGet(buf: i64, index_in: i64) i64 {
    const b = fromHandle(buf);
    const i: usize = @intCast(index_in);
    if (i >= b.len) return 0;
    return b.data[i];
}

export fn __bufferSet(buf: i64, index_in: i64, val_in: i64) i64 {
    const b = fromHandle(buf);
    const i: usize = @intCast(index_in);
    if (i >= b.len) return val_in;
    b.data[i] = @truncate(@as(u64, @bitCast(val_in)));
    return val_in;
}

export fn __bufferPush(buf: i64, val_in: i64) i64 {
    const b = fromHandle(buf);
    grow(b, b.len + 1);
    b.data[b.len] = @truncate(@as(u64, @bitCast(val_in)));
    b.len += 1;
    return val_in;
}

export fn __bufferCopy(dst: i64, dst_off: i64, src: i64, src_off: i64, len_in: i64) i64 {
    const d = fromHandle(dst);
    const s = fromHandle(src);
    const doff: usize = @intCast(dst_off);
    const soff: usize = @intCast(src_off);
    const n: usize = @intCast(len_in);
    if (doff > d.len or n > d.len - doff or soff > s.len or n > s.len - soff) return -1;
    const dst_slice = d.data[doff .. doff + n];
    const src_slice = s.data[soff .. soff + n];
    if (@intFromPtr(dst_slice.ptr) == @intFromPtr(src_slice.ptr)) return len_in;
    if (@intFromPtr(dst_slice.ptr) < @intFromPtr(src_slice.ptr)) {
        std.mem.copyForwards(u8, dst_slice, src_slice);
    } else {
        std.mem.copyBackwards(u8, dst_slice, src_slice);
    }
    return len_in;
}

export fn __bufferFill(buf: i64, val_in: i64) i64 {
    const b = fromHandle(buf);
    @memset(b.data[0..b.len], @truncate(@as(u64, @bitCast(val_in))));
    return val_in;
}

export fn __bufferFillRange(buf: i64, val_in: i64, start_in: i64, len_in: i64) i64 {
    const b = fromHandle(buf);
    const start: usize = @intCast(start_in);
    const n: usize = @intCast(len_in);
    if (start > b.len or n > b.len - start) return -1;
    @memset(b.data[start .. start + n], @truncate(@as(u64, @bitCast(val_in))));
    return val_in;
}

export fn __bufferResize(buf: i64, new_len_in: i64) i64 {
    const b = fromHandle(buf);
    if (new_len_in < 0) return -1;
    const new_len: usize = @intCast(new_len_in);
    if (new_len > b.cap) {
        const cap = @max(new_len, 16);
        const data = std.heap.page_allocator.realloc(b.data[0..b.cap], cap) catch return -1;
        b.data = data.ptr;
        b.cap = cap;
    }
    if (new_len > b.len) @memset(b.data[b.len..new_len], 0);
    b.len = new_len;
    return new_len_in;
}
