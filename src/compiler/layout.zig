//! Packed byte layout for structs (Track B step 2).

const std = @import("std");
const state_mod = @import("state.zig");
const widths = @import("widths.zig");

/// Packed field storage kinds. Numeric kinds 10+ match `widths.Width` + offset.
pub const FieldKind = enum(u8) {
    i64 = 0,
    f64 = 1,
    u1 = 2, // was bool; bool/boolean → u1
    handle = 3,
    ptr = 4,
    u8 = 5,
    f32 = 6,
    i8 = 7,
    i16 = 8,
    i32 = 9,
    u16 = 10,
    u32 = 11,
    u64 = 12,
};

pub const HANDLE_NULL_OFFSET: u32 = 0xFFFF_FFFF;

pub fn alignUp(offset: i32, alignment: i32) i32 {
    const a = alignment - 1;
    return (offset + a) & ~a;
}

pub fn sizeOfTypeName(type_name: []const u8) i32 {
    const bare = unwrapTypeName(type_name);
    if (bare.len > 0 and bare[0] == '*') return 8; // pointer / heap handle
    if (widths.fromName(bare)) |w| return w.size();
    if (std.mem.eql(u8, bare, "null"))
        return 0;
    if (std.mem.eql(u8, bare, "string") or std.mem.eql(u8, bare, "[]byte"))
        return 8;
    return 8;
}

/// Size of a named type when enum/struct defs are available.
pub fn sizeOfNamedType(state: *state_mod.CompilerState, type_name: []const u8) i32 {
    const bare = unwrapTypeName(type_name);
    if (state.enums.contains(bare)) return 8; // tag-only i64
    if (state.structs.get(bare)) |sd| return sd.size;
    return sizeOfTypeName(type_name);
}

pub fn alignOfTypeName(type_name: []const u8) i32 {
    const bare = unwrapTypeName(type_name);
    if (bare.len > 0 and bare[0] == '*') return 8;
    if (widths.fromName(bare)) |w| return w.alignment();
    if (std.mem.eql(u8, bare, "null"))
        return 1;
    return 8;
}

pub fn fieldKind(state: ?*state_mod.CompilerState, type_name: []const u8) FieldKind {
    const bare = unwrapTypeName(type_name);
    if (bare.len > 0 and bare[0] == '*') return .handle;
    if (widths.fromName(bare)) |w| return fieldKindFromWidth(w);
    if (std.mem.eql(u8, bare, "ptr"))
        return .ptr;
    // Tag-only enums / enum literals are i64 on the wire.
    if (state) |st| {
        if (st.enums.contains(bare)) return .i64;
        if (std.mem.lastIndexOfScalar(u8, bare, '.')) |dot| {
            const ename = bare[0..dot];
            if (st.enums.contains(ename)) return .i64;
        }
    }
    return .handle;
}

pub fn fieldKindFromWidth(w: widths.Width) FieldKind {
    return switch (w) {
        .u1 => .u1,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
    };
}

pub fn widthFromFieldKind(kind: FieldKind) ?widths.Width {
    return switch (kind) {
        .u1 => .u1,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
        else => null,
    };
}

pub fn unwrapTypeName(type_name: []const u8) []const u8 {
    var s = type_name;
    while (s.len > 0 and s[0] == '?') s = s[1..];
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

pub fn fieldKindForStruct(state: *state_mod.CompilerState, sd: state_mod.StructDef, field: []const u8) FieldKind {
    const ty = sd.types.get(field) orelse "i64";
    return fieldKind(state, ty);
}
