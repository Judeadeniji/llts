//! LLTS native map functions — mirrors `src/vm/builtins/map.zig`.
//!
//! Opaque handles: `map.create()` returns an i64 (pointer to a MapState).
//! Keys are always C strings (i64 = pointer to NUL-terminated bytes). Values
//! are bare i64 (the flat encoding the LLVM backend uses for everything).

const std = @import("std");
const util = @import("util.zig");

const MapState = struct {
    entries: std.StringHashMap(i64),
};

fn mapFromHandle(h: i64) ?*MapState {
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

fn ensureMap(h: i64) ?*MapState {
    const m = mapFromHandle(h) orelse return null;
    if (@intFromPtr(m) < 4096) return null;
    return m;
}

export fn __mapCreate() i64 {
    const alloc = util.strAlloc();
    const ms = alloc.create(MapState) catch return 0;
    ms.* = .{ .entries = std.StringHashMap(i64).init(alloc) };
    return @intCast(@intFromPtr(ms));
}

export fn __mapSet(mp: i64, key: i64, value: i64) i64 {
    const m = ensureMap(mp) orelse return 0;
    const alloc = util.strAlloc();
    const key_str = util.cstr(@ptrFromInt(@as(usize, @intCast(key))));
    const gop = m.entries.getOrPut(key_str) catch return 0;
    if (!gop.found_existing) {
        gop.key_ptr.* = alloc.dupe(u8, key_str) catch return 0;
    }
    gop.value_ptr.* = value;
    return value;
}

export fn __mapGet(mp: i64, key: i64) i64 {
    const m = ensureMap(mp) orelse return 0;
    const key_str = util.cstr(@ptrFromInt(@as(usize, @intCast(key))));
    if (m.entries.get(key_str)) |v| return v;
    return 0; // null sentinel
}

export fn __mapHas(mp: i64, key: i64) i64 {
    const m = ensureMap(mp) orelse return 0;
    const key_str = util.cstr(@ptrFromInt(@as(usize, @intCast(key))));
    return if (m.entries.contains(key_str)) 1 else 0;
}

export fn __mapDelete(mp: i64, key: i64) i64 {
    const m = ensureMap(mp) orelse return 0;
    const key_str = util.cstr(@ptrFromInt(@as(usize, @intCast(key))));
    if (m.entries.fetchRemove(key_str)) |_| return 1;
    return 0;
}

export fn __mapSize(mp: i64) i64 {
    const m = ensureMap(mp) orelse return 0;
    return @intCast(m.entries.count());
}
