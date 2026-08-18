//! LLTS native JSON functions — mirrors `src/vm/builtins/json_builtin.zig`.
//!
//! `__jsonParse(str)` returns an i64 handle to a tagged JSON tree allocated
//! in the string bump arena.  `__jsonStringify(val)` walks the tree and
//! returns a NUL-terminated C string.
//!
//! JSON nodes are heap-allocated `JsonNode` records.  Objects store entries as
//! a flat key/value pair array so member access can scan by key.  Arrays store
//! item pointers.

const std = @import("std");
const util = @import("util.zig");

const dupBytes = util.dupBytes;
const cstr = util.cstr;

// ─────────────────────────── tagged value tree ────────────────────────────

pub const JsonValue = enum(u8) {
    null = 0,
    bool_val,
    int,
    float,
    string,
    array,
    object,
};

pub const ObjectEntry = struct {
    key: [*:0]const u8,
    value: *JsonNode,
};

pub const JsonNode = extern struct {
    kind: JsonValue,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    // Payload — reinterpret according to `kind`:
    //   .null      → unused
    //   .bool_val  → payload_i (0 or 1)
    //   .int       → payload_i (signed)
    //   .float     → payload_f
    //   .string    → payload_ptr (NUL-terminated C string)
    //   .array     → payload_ptr → ArrayWrap
    //   .object    → payload_ptr → ObjectWrap
    payload_i: i64 = 0,
    payload_f: f64 = 0,
    payload_ptr: ?*anyopaque = null,
};

// Wrappers that hold the array/object data (non-extern, flexible).
const ArrayWrap = struct {
    len: i64,
    items: [*]?*JsonNode,
};

const ObjectWrap = struct {
    len: i64,
    entries: [*]ObjectEntry,
};

var dummy: JsonNode = .{ .kind = .null };

fn getArrayWrap(n: *JsonNode) ?*ArrayWrap {
    if (n.kind != .array) return null;
    return @ptrCast(@alignCast(n.payload_ptr));
}

fn getObjectWrap(n: *JsonNode) ?*ObjectWrap {
    if (n.kind != .object) return null;
    return @ptrCast(@alignCast(n.payload_ptr));
}

// ─────────────────────────── parse ────────────────────────────────────────

fn parseJson(val: std.json.Value) *JsonNode {
    const alloc = util.strAlloc();
    const node: *JsonNode = alloc.create(JsonNode) catch return &dummy;
    switch (val) {
        .null => {
            node.* = .{ .kind = .null };
        },
        .bool => |b| {
            node.* = .{ .kind = .bool_val, .payload_i = if (b) 1 else 0 };
        },
        .integer => |i| {
            node.* = .{ .kind = .int, .payload_i = @intCast(i) };
        },
        .float => |f| {
            node.* = .{ .kind = .float, .payload_f = f };
        },
        .string => |s| {
            node.* = .{ .kind = .string, .payload_ptr = dupBytes(s) };
        },
        .array => |arr| {
            const item_ptrs = alloc.alloc(?*JsonNode, arr.items.len) catch return &dummy;
            for (arr.items, 0..) |item, i| {
                item_ptrs[i] = parseJson(item);
            }
            const wrap = alloc.create(ArrayWrap) catch return &dummy;
            wrap.* = .{ .len = @intCast(arr.items.len), .items = item_ptrs.ptr };
            node.* = .{ .kind = .array, .payload_ptr = wrap };
        },
        .object => |obj| {
            const count = obj.count();
            const entries = alloc.alloc(ObjectEntry, count) catch return &dummy;
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| {
                entries[idx] = .{
                    .key = dupBytes(entry.key_ptr.*),
                    .value = parseJson(entry.value_ptr.*),
                };
                idx += 1;
            }
            const wrap = alloc.create(ObjectWrap) catch return &dummy;
            wrap.* = .{ .len = @intCast(count), .entries = entries.ptr };
            node.* = .{ .kind = .object, .payload_ptr = wrap };
        },
        else => {
            node.* = .{ .kind = .null };
        },
    }
    return node;
}

// ─────────────────────────── export fns ───────────────────────────────────

export fn __jsonParse(str: [*:0]const u8) i64 {
    const source = cstr(str);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, source, .{}) catch {
        return util.errNew(dupBytes("JsonError"), 0);
    };
    defer parsed.deinit();
    const node = parseJson(parsed.value);
    return @intCast(@intFromPtr(node));
}

export fn __jsonStringify(val: i64) ?[*:0]u8 {
    if (val == 0) return dupBytes("null");
    const node: *JsonNode = @ptrFromInt(@as(usize, @intCast(val)));
    const alloc = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    stringifyNode(node, &buf, alloc) catch return dupBytes("[StringifyError]");
    return dupBytes(buf.items);
}

// ─────────────────────────── stringify helpers ────────────────────────────

fn stringifyNode(node: *JsonNode, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    switch (node.kind) {
        .null => try out.appendSlice(alloc, "null"),
        .bool_val => try out.appendSlice(alloc, if (node.payload_i != 0) "true" else "false"),
        .int => try out.writer(alloc).print("{d}", .{node.payload_i}),
        .float => try out.writer(alloc).print("{d}", .{node.payload_f}),
        .string => {
            try out.append(alloc, '"');
            const s: [*:0]const u8 = @ptrCast(@alignCast(node.payload_ptr));
            try out.appendSlice(alloc, cstr(s));
            try out.append(alloc, '"');
        },
        .array => {
            const wrap = getArrayWrap(node) orelse {
                try out.appendSlice(alloc, "[]");
                return;
            };
            try out.append(alloc, '[');
            for (0..@intCast(wrap.len)) |i| {
                if (i > 0) try out.append(alloc, ',');
                if (wrap.items[i]) |item| {
                    try stringifyNode(item, out, alloc);
                } else {
                    try out.appendSlice(alloc, "null");
                }
            }
            try out.append(alloc, ']');
        },
        .object => {
            const wrap = getObjectWrap(node) orelse {
                try out.appendSlice(alloc, "{}");
                return;
            };
            try out.append(alloc, '{');
            for (0..@intCast(wrap.len)) |i| {
                if (i > 0) try out.append(alloc, ',');
                // Key
                try out.append(alloc, '"');
                try out.appendSlice(alloc, cstr(wrap.entries[i].key));
                try out.appendSlice(alloc, "\":");
                // Value
                try stringifyNode(wrap.entries[i].value, out, alloc);
            }
            try out.append(alloc, '}');
        },
    }
}

// ─────────────────────────── accessors for the backend ────────────────────
// These are called by the LLVM backend for JSON member/index/len access.

/// Get an object field by key — returns the node handle or 0.
export fn __jsonGet(obj: i64, key: [*:0]const u8) i64 {
    if (obj == 0) return 0;
    const node: *JsonNode = @ptrFromInt(@as(usize, @intCast(obj)));
    const wrap = getObjectWrap(node) orelse return 0;
    const key_c = cstr(key);
    for (0..@intCast(wrap.len)) |i| {
        if (std.mem.eql(u8, cstr(wrap.entries[i].key), key_c)) {
            return @intCast(@intFromPtr(wrap.entries[i].value));
        }
    }
    return 0;
}

/// Get an array element by index — returns the node handle or 0.
export fn __jsonIndex(arr: i64, index: i64) i64 {
    if (arr == 0 or index < 0) return 0;
    const node: *JsonNode = @ptrFromInt(@as(usize, @intCast(arr)));
    const wrap = getArrayWrap(node) orelse return 0;
    const idx: usize = @intCast(index);
    if (idx >= wrap.len) return 0;
    if (wrap.items[idx]) |item| {
        return @intCast(@intFromPtr(item));
    }
    return 0;
}

/// Length of an array or object.
export fn __jsonLen(val: i64) i64 {
    if (val == 0) return 0;
    const node: *JsonNode = @ptrFromInt(@as(usize, @intCast(val)));
    switch (node.kind) {
        .array => {
            const wrap = getArrayWrap(node) orelse return 0;
            return wrap.len;
        },
        .object => {
            const wrap = getObjectWrap(node) orelse return 0;
            return wrap.len;
        },
        else => return 0,
    }
}

/// Convert a JSON node to its string representation (unquoted for primitives).
export fn __jsonToString(val: i64) ?[*:0]u8 {
    if (val == 0) return dupBytes("null");
    const node: *JsonNode = @ptrFromInt(@as(usize, @intCast(val)));
    const alloc = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    switch (node.kind) {
        .null => {
            buf.appendSlice(alloc, "null") catch return dupBytes("null");
        },
        .bool_val => {
            buf.appendSlice(alloc, if (node.payload_i != 0) "true" else "false") catch return dupBytes("null");
        },
        .int => {
            buf.writer(alloc).print("{d}", .{node.payload_i}) catch return dupBytes("null");
        },
        .float => {
            buf.writer(alloc).print("{d}", .{node.payload_f}) catch return dupBytes("null");
        },
        .string => {
            const s: [*:0]const u8 = @ptrCast(@alignCast(node.payload_ptr));
            buf.appendSlice(alloc, cstr(s)) catch return dupBytes("null");
        },
        else => {
            // For arrays/objects, fall back to full stringify.
            return __jsonStringify(val);
        },
    }
    return dupBytes(buf.items);
}
