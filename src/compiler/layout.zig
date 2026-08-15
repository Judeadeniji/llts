//! Packed byte layout for structs (Track B step 2).
//! Alignment: 8 for i64/f64/handles, 1 for bool/u8. No implicit padding beyond align rules.

const std = @import("std");
const state_mod = @import("state.zig");

pub const FieldKind = enum(u8) {
    i64 = 0,
    f64 = 1,
    bool = 2,
    /// `.slice` / `.bytes` / nested packed struct handle: u32 offset + u32 len.
    handle = 3,
    /// Value-slot `.ptr` (errors / legacy): i32, 8-byte aligned slot.
    ptr = 4,
    /// Single byte 0..255 (future `u8` / `byte` fields).
    u8 = 5,
};

pub const HANDLE_NULL_OFFSET: u32 = 0xFFFF_FFFF;

pub fn alignUp(offset: i32, alignment: i32) i32 {
    const a = alignment - 1;
    return (offset + a) & ~a;
}

pub fn sizeOfTypeName(type_name: []const u8) i32 {
    const bare = unwrapTypeName(type_name);
    if (std.mem.eql(u8, bare, "int") or std.mem.eql(u8, bare, "i32") or
        std.mem.eql(u8, bare, "i64") or std.mem.eql(u8, bare, "number"))
        return 8;
    if (std.mem.eql(u8, bare, "float") or std.mem.eql(u8, bare, "f64") or std.mem.eql(u8, bare, "f32"))
        return 8;
    if (std.mem.eql(u8, bare, "bool") or std.mem.eql(u8, bare, "boolean"))
        return 1;
    if (std.mem.eql(u8, bare, "null"))
        return 0;
    if (std.mem.eql(u8, bare, "byte") or std.mem.eql(u8, bare, "u8"))
        return 1;
    if (std.mem.eql(u8, bare, "string") or std.mem.eql(u8, bare, "[]byte"))
        return 8;
    // Named structs / optionals / unions → packed handle.
    return 8;
}

pub fn alignOfTypeName(type_name: []const u8) i32 {
    const bare = unwrapTypeName(type_name);
    if (std.mem.eql(u8, bare, "bool") or std.mem.eql(u8, bare, "boolean") or
        std.mem.eql(u8, bare, "byte") or std.mem.eql(u8, bare, "u8") or
        std.mem.eql(u8, bare, "null"))
        return 1;
    return 8;
}

pub fn fieldKind(type_name: []const u8) FieldKind {
    const bare = unwrapTypeName(type_name);
    if (std.mem.eql(u8, bare, "int") or std.mem.eql(u8, bare, "i32") or
        std.mem.eql(u8, bare, "i64") or std.mem.eql(u8, bare, "number"))
        return .i64;
    if (std.mem.eql(u8, bare, "float") or std.mem.eql(u8, bare, "f64") or std.mem.eql(u8, bare, "f32"))
        return .f64;
    if (std.mem.eql(u8, bare, "bool") or std.mem.eql(u8, bare, "boolean"))
        return .bool;
    if (std.mem.eql(u8, bare, "byte") or std.mem.eql(u8, bare, "u8"))
        return .u8;
    // error message field etc. — handle; Value-heap ptrs use .ptr only when annotated "ptr" (rare).
    if (std.mem.eql(u8, bare, "ptr"))
        return .ptr;
    return .handle;
}

/// Strip `?T` / `T | null` / `T | error` to the payload type name for layout sizing.
pub fn unwrapTypeName(type_name: []const u8) []const u8 {
    var s = type_name;
    if (std.mem.startsWith(u8, s, "?")) s = s[1..];
    if (std.mem.indexOf(u8, s, " | ")) |idx| {
        s = std.mem.trim(u8, s[0..idx], " ");
    }
    return s;
}

pub const LayoutResult = struct {
    size: i32,
    offsets: std.StringHashMap(i32),
};

pub const FieldSpec = struct {
    name: []const u8,
    type_name: []const u8,
};

/// Compute packed field offsets and total byte size (aligned to 8).
pub fn layoutFields(
    allocator: std.mem.Allocator,
    fields: []const FieldSpec,
) !LayoutResult {
    var offsets = std.StringHashMap(i32).init(allocator);
    errdefer offsets.deinit();
    var offset: i32 = 0;
    var max_align: i32 = 1;
    for (fields) |f| {
        const al = alignOfTypeName(f.type_name);
        const sz = sizeOfTypeName(f.type_name);
        if (sz == 0) {
            try offsets.put(f.name, offset);
            continue;
        }
        offset = alignUp(offset, al);
        try offsets.put(f.name, offset);
        offset += sz;
        if (al > max_align) max_align = al;
    }
    const size = if (offset == 0) 0 else alignUp(offset, @max(max_align, 8));
    return .{ .size = size, .offsets = offsets };
}

pub fn fieldKindForStruct(sd: state_mod.StructDef, field: []const u8) FieldKind {
    const ty = sd.types.get(field) orelse "int";
    return fieldKind(ty);
}
