//! LLTS native list functions — mirrors `src/vm/builtins/list.zig`.
//!
//! Opaque handles: `list.create()` returns an i64 (pointer to a ListState).
//! All other functions dereference the handle. Values are bare i64 (the same
//! flat encoding the LLVM backend uses for everything).

const std = @import("std");
const util = @import("util.zig");

const ListState = struct {
    items: std.ArrayList(i64),
};

fn listFromHandle(h: i64) ?*ListState {
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

fn ensureList(h: i64) ?*ListState {
    const l = listFromHandle(h) orelse return null;
    if (@intFromPtr(l) < 4096) return null; // guard against garbage
    return l;
}

export fn __listCreate() i64 {
    const alloc = util.strAlloc();
    const ls = alloc.create(ListState) catch return 0;
    ls.* = .{ .items = .empty };
    return @intCast(@intFromPtr(ls));
}

export fn __listPush(lst: i64, item: i64) i64 {
    const l = ensureList(lst) orelse return 0;
    l.items.append(util.strAlloc(), item) catch return 0;
    return lst;
}

export fn __listPop(lst: i64) i64 {
    const l = ensureList(lst) orelse return util.errNew(dupBytes("ListError"), 0);
    if (l.items.pop()) |v| return v;
    return 0; // null sentinel
}

export fn __listGet(lst: i64, index: i64) i64 {
    const l = ensureList(lst) orelse return util.errNew(dupBytes("IndexError"), 0);
    if (index < 0 or @as(usize, @intCast(index)) >= l.items.items.len)
        return util.errNew(dupBytes("IndexError"), @bitCast(@as(u64, @intCast(index))));
    return l.items.items[@intCast(index)];
}

export fn __listSet(lst: i64, index: i64, item: i64) i64 {
    const l = ensureList(lst) orelse return util.errNew(dupBytes("IndexError"), 0);
    if (index < 0 or @as(usize, @intCast(index)) >= l.items.items.len)
        return util.errNew(dupBytes("IndexError"), @bitCast(@as(u64, @intCast(index))));
    l.items.items[@intCast(index)] = item;
    return item;
}

export fn __listLen(lst: i64) i64 {
    const l = ensureList(lst) orelse return 0;
    return @intCast(l.items.items.len);
}

const dupBytes = util.dupBytes;
