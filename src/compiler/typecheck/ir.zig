const std = @import("std");
const widths = @import("../widths.zig");

pub const TypeTag = enum(u8) {
    i64 = 1,
    u1 = 2, // was bool; bool/boolean alias u1
    string = 3,
    null = 4,
    error_ = 5,
    array = 6,
    struct_ = 7,
    error_union = 8,
    u8 = 9,
    f32 = 10,
    f64 = 11,
    i8 = 12,
    i16 = 13,
    i32 = 14,
    u16 = 15,
    u32 = 16,
    u64 = 17,
};

pub const Type = union(enum) {
    u1,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    null,
    error_,
    unknown,
    never,
    struct_: []const u8,
    enum_: []const u8,
    /// Singleton enum variant used as a type (`ExprKind.Literal`).
    enum_lit: struct { enum_name: []const u8, variant: []const u8 },
    array: struct { elem: *Type, length: ?usize },
    ptr: *Type,
    union_: []Type,
    /// Go-style distinct `@type Name = T` (aliases unwrap and never appear here).
    defined: struct { name: []const u8, underlying: *Type },
};

pub const TUnknown: Type = .{ .unknown = {} };
pub const TU1: Type = .{ .u1 = {} };
/// Alias for u1 (`bool` / `boolean`).
pub const TBool: Type = TU1;
pub const TI8: Type = .{ .i8 = {} };
pub const TI16: Type = .{ .i16 = {} };
pub const TI32: Type = .{ .i32 = {} };
pub const TI64: Type = .{ .i64 = {} };
/// Alias for the default integer width (`int` / `number` → i64).
pub const TInt: Type = TI64;
pub const TU8: Type = .{ .u8 = {} };
pub const TU16: Type = .{ .u16 = {} };
pub const TU32: Type = .{ .u32 = {} };
pub const TU64: Type = .{ .u64 = {} };
/// Alias for u8 (`byte`).
pub const TByte: Type = TU8;
pub const TF32: Type = .{ .f32 = {} };
pub const TF64: Type = .{ .f64 = {} };
pub const TNull: Type = .{ .null = {} };
pub const TError: Type = .{ .error_ = {} };
pub const TNever: Type = .{ .never = {} };

var byte_elem: Type = .{ .u8 = {} };
pub const TString: Type = .{ .array = .{ .elem = &byte_elem, .length = null } };

/// Allocator used while building type trees during a typecheck pass.
pub const TypeAlloc = struct {
    allocator: std.mem.Allocator,

    pub fn allocType(self: TypeAlloc, t: Type) !*Type {
        const p = try self.allocator.create(Type);
        p.* = t;
        return p;
    }

    pub fn arrayType(self: TypeAlloc, elem: Type, length: ?usize) !Type {
        const ep = try self.allocType(elem);
        return .{ .array = .{ .elem = ep, .length = length } };
    }

    pub fn ptrType(self: TypeAlloc, elem: Type) !Type {
        const ep = try self.allocType(elem);
        return .{ .ptr = ep };
    }

    pub fn unionType(self: TypeAlloc, arms: []const Type) !Type {
        var flat: std.ArrayList(Type) = .empty;
        defer flat.deinit(self.allocator);
        for (arms) |a| {
            switch (a) {
                .union_ => |inner| try flat.appendSlice(self.allocator, inner),
                .never => {},
                else => try flat.append(self.allocator, a),
            }
        }
        var unique: std.ArrayList(Type) = .empty;
        errdefer unique.deinit(self.allocator);
        for (flat.items) |a| {
            var found = false;
            for (unique.items) |u| {
                if (typeEquals(a, u)) {
                    found = true;
                    break;
                }
            }
            if (!found) try unique.append(self.allocator, a);
        }
        if (unique.items.len == 0) return TNever;
        if (unique.items.len == 1) {
            const only = unique.items[0];
            unique.deinit(self.allocator);
            return only;
        }
        const slice = try unique.toOwnedSlice(self.allocator);
        return .{ .union_ = slice };
    }

    pub fn definedType(self: TypeAlloc, name: []const u8, underlying: Type) !Type {
        const up = try self.allocType(underlying);
        return .{ .defined = .{ .name = name, .underlying = up } };
    }
};

/// Ultimate non-defined / non-alias shape (follows `.defined` chain).
pub fn peelDefined(t: Type) Type {
    var cur = t;
    while (cur == .defined) cur = cur.defined.underlying.*;
    return cur;
}

pub fn typeFromWidth(w: widths.Width) Type {
    return switch (w) {
        .u1 => TU1,
        .i8 => TI8,
        .i16 => TI16,
        .i32 => TI32,
        .i64 => TI64,
        .u8 => TU8,
        .u16 => TU16,
        .u32 => TU32,
        .u64 => TU64,
        .f32 => TF32,
        .f64 => TF64,
    };
}

pub fn widthOf(t: Type) ?widths.Width {
    return switch (t) {
        .defined => |d| widthOf(d.underlying.*),
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

pub fn namedType(name: []const u8) Type {
    if (widths.fromName(name)) |w| return typeFromWidth(w);
    if (std.mem.eql(u8, name, "null")) return TNull;
    if (std.mem.eql(u8, name, "error")) return TError;
    if (std.mem.eql(u8, name, "string")) return TString;
    if (std.mem.eql(u8, name, "unknown")) return TUnknown;
    return .{ .struct_ = name };
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    return switch (namedType(name)) {
        .struct_ => false,
        else => true,
    };
}

pub fn isNumeric(t: Type) bool {
    return widthOf(t) != null;
}

pub fn isInteger(t: Type) bool {
    return if (widthOf(t)) |w| !w.isFloat() else false;
}

fn displayWidth(t: Type) []const u8 {
    return widthOf(t).?.name();
}

pub fn displayTypeAlloc(allocator: std.mem.Allocator, t: Type) ![]const u8 {
    return switch (t) {
        .u1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64 => try allocator.dupe(u8, displayWidth(t)),
        .null => try allocator.dupe(u8, "null"),
        .error_ => try allocator.dupe(u8, "error"),
        .unknown => try allocator.dupe(u8, "unknown"),
        .never => try allocator.dupe(u8, "never"),
        .struct_ => |n| try allocator.dupe(u8, n),
        .enum_ => |n| try allocator.dupe(u8, n),
        .enum_lit => |e| try std.fmt.allocPrint(allocator, "{s}.{s}", .{ e.enum_name, e.variant }),
        .array => |a| blk: {
            const elem = try displayTypeAlloc(allocator, a.elem.*);
            defer allocator.free(elem);
            // Prefer `[]byte` spelling for u8 slices (string ≡ []byte).
            const elem_disp = if (a.elem.* == .u8) "byte" else elem;
            if (a.length) |len| {
                break :blk try std.fmt.allocPrint(allocator, "[{d}]{s}", .{ len, elem_disp });
            }
            break :blk try std.fmt.allocPrint(allocator, "[]{s}", .{elem_disp});
        },
        .ptr => |p| blk: {
            const inner = try displayTypeAlloc(allocator, p.*);
            defer allocator.free(inner);
            break :blk try std.fmt.allocPrint(allocator, "*{s}", .{inner});
        },
        .defined => |d| try allocator.dupe(u8, d.name),
        .union_ => |arms| blk: {
            if (optionalPayload(t)) |payload| {
                const inner = try displayTypeAlloc(allocator, payload);
                defer allocator.free(inner);
                break :blk try std.fmt.allocPrint(allocator, "?{s}", .{inner});
            }
            var parts: std.ArrayList([]const u8) = .empty;
            defer {
                for (parts.items) |p| allocator.free(p);
                parts.deinit(allocator);
            }
            for (arms) |arm| try parts.append(allocator, try displayTypeAlloc(allocator, arm));
            var total: usize = 0;
            for (parts.items, 0..) |p, i| {
                total += p.len;
                if (i > 0) total += 3;
            }
            const out = try allocator.alloc(u8, total);
            var offset: usize = 0;
            for (parts.items, 0..) |p, i| {
                if (i > 0) {
                    @memcpy(out[offset .. offset + 3], " | ");
                    offset += 3;
                }
                @memcpy(out[offset .. offset + p.len], p);
                offset += p.len;
            }
            break :blk out;
        },
    };
}

pub fn displayTypeSimple(t: Type) ?[]const u8 {
    return switch (t) {
        .u1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64 => displayWidth(t),
        .null => "null",
        .error_ => "error",
        .unknown => "unknown",
        .never => "never",
        .struct_ => |n| n,
        .enum_ => |n| n,
        .enum_lit => null,
        .array => |a| if (a.elem.* == .u8 and a.length == null) "[]byte" else null,
        .ptr, .union_ => null,
        .defined => |d| d.name,
    };
}

pub fn displayType(t: Type) []const u8 {
    return displayTypeSimple(t) orelse "unknown";
}

pub fn typeEquals(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        if (a == .union_ or b == .union_) {
            // Fall through
        } else if ((a == .struct_ or a == .enum_) and (b == .struct_ or b == .enum_)) {
            // Fall through
        } else return false;
    }
    return switch (a) {
        .struct_ => |n| (b == .struct_ and std.mem.eql(u8, n, b.struct_)) or (b == .enum_ and std.mem.eql(u8, n, b.enum_)),
        .enum_ => |n| (b == .enum_ and std.mem.eql(u8, n, b.enum_)) or (b == .struct_ and std.mem.eql(u8, n, b.struct_)),
        .enum_lit => |e| b == .enum_lit and std.mem.eql(u8, e.enum_name, b.enum_lit.enum_name) and std.mem.eql(u8, e.variant, b.enum_lit.variant),
        .array => |aa| b == .array and aa.length == b.array.length and typeEquals(aa.elem.*, b.array.elem.*),
        .ptr => |p| b == .ptr and typeEquals(p.*, b.ptr.*),
        .defined => |d| b == .defined and std.mem.eql(u8, d.name, b.defined.name),
        .union_ => |arms| blk: {
            if (b != .union_) break :blk false;
            if (arms.len != b.union_.len) break :blk false;
            for (arms) |arm| {
                var found = false;
                for (b.union_) |other| {
                    if (typeEquals(arm, other)) {
                        found = true;
                        break;
                    }
                }
                if (!found) break :blk false;
            }
            break :blk true;
        },
        .u1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .null, .error_, .unknown, .never => std.meta.activeTag(a) == std.meta.activeTag(b),
    };
}

pub fn optionalPayload(t: Type) ?Type {
    if (t != .union_) return null;
    var payload: ?Type = null;
    var saw_null = false;
    for (t.union_) |arm| {
        if (arm == .null) {
            saw_null = true;
            continue;
        }
        if (payload != null) return null;
        payload = arm;
    }
    if (!saw_null) return null;
    return payload;
}

pub fn structNameOf(t: Type) ?[]const u8 {
    return switch (t) {
        .struct_ => |n| n,
        .ptr => |p| structNameOf(p.*),
        .defined => |d| structNameOf(d.underlying.*),
        else => if (optionalPayload(t)) |p| structNameOf(p) else null,
    };
}

pub fn isSubtype(a: Type, b: Type) bool {
    if (a == .never) return true;
    if (b == .unknown or a == .unknown) return true;
    if (typeEquals(a, b)) return true;

    // Distinct `@type`: coerce *into* Name from underlying-compatible values;
    // do not silently unwrap Name when used as a value.
    if (b == .defined) {
        if (a == .defined) return std.mem.eql(u8, a.defined.name, b.defined.name);
        return isSubtype(a, b.defined.underlying.*);
    }
    if (a == .defined) return false;

    if (b == .union_) {
        for (b.union_) |arm| {
            if (isSubtype(a, arm)) return true;
        }
        return false;
    }
    if (a == .union_) {
        for (a.union_) |arm| {
            if (!isSubtype(arm, b)) return false;
        }
        return true;
    }

    if (a == .array and b == .array) {
        if (!isSubtype(a.array.elem.*, b.array.elem.*)) return false;
        if (b.array.length == null) return true;
        if (a.array.length == null) return false;
        return a.array.length.? == b.array.length.?;
    }
    if (a == .ptr and b == .ptr) {
        return typeEquals(a.ptr.*, b.ptr.*);
    }
    // Enum literal ⊑ parent enum; parent enum ≰ literal (need static variant proof).
    if (a == .enum_lit and b == .enum_) {
        return std.mem.eql(u8, a.enum_lit.enum_name, b.enum_);
    }
    if (a == .enum_lit and b == .enum_lit) {
        return typeEquals(a, b);
    }
    // Tag-only enums / literals are i64-backed.
    if ((a == .enum_ or a == .enum_lit) and b == .i64) return true;
    if (a == .i64 and b == .enum_) return true;
    return false;
}

pub fn involvesUnknown(t: Type) bool {
    return switch (t) {
        .unknown => true,
        .array => |a| involvesUnknown(a.elem.*),
        .ptr => |p| involvesUnknown(p.*),
        .defined => |d| involvesUnknown(d.underlying.*),
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (involvesUnknown(arm)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn isErrorUnion(t: Type) bool {
    return switch (t) {
        .error_ => true,
        .defined => |d| isErrorUnion(d.underlying.*),
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (arm == .error_) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn allowsError(t: Type) bool {
    return switch (t) {
        .error_, .unknown => true,
        .defined => |d| allowsError(d.underlying.*),
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (arm == .error_) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn unwrapError(ta: TypeAlloc, t: Type) !Type {
    return switch (t) {
        .error_ => TNever,
        .defined => |d| try unwrapError(ta, d.underlying.*),
        .union_ => |arms| blk: {
            var kept: std.ArrayList(Type) = .empty;
            defer kept.deinit(ta.allocator);
            for (arms) |arm| {
                if (arm != .error_) try kept.append(ta.allocator, arm);
            }
            break :blk try ta.unionType(kept.items);
        },
        else => t,
    };
}

pub fn isByteSlice(t: Type) bool {
    const p = peelDefined(t);
    return p == .array and p.array.elem.* == .u8;
}

pub fn typeTag(t: Type) ?TypeTag {
    return switch (peelDefined(t)) {
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
        .u1 => .u1,
        .null => .null,
        .error_ => .error_,
        .array => |a| if (a.elem.* == .u8) .string else .array,
        .struct_ => .struct_,
        .enum_, .enum_lit => .i64,
        .union_ => |u| if (isErrorUnion(.{ .union_ = u })) .error_union else null,
        else => null,
    };
}

pub fn parseDisplayType(ta: TypeAlloc, s_in: []const u8) !Type {
    const s = std.mem.trim(u8, s_in, " \t");
    const union_parts = try splitTopLevel(ta.allocator, s, " | ");
    defer ta.allocator.free(union_parts);
    if (union_parts.len > 1) {
        var arms: std.ArrayList(Type) = .empty;
        defer arms.deinit(ta.allocator);
        for (union_parts) |part| {
            try arms.append(ta.allocator, try parseDisplayType(ta, part));
        }
        return try ta.unionType(arms.items);
    }
    if (s.len > 0 and s[0] == '?') {
        const inner = try parseDisplayType(ta, s[1..]);
        return try ta.unionType(&.{ inner, TNull });
    }
    if (s.len > 0 and s[0] == '*') {
        return try ta.ptrType(try parseDisplayType(ta, s[1..]));
    }
    if (s.len > 0 and s[0] == '[') {
        if (s.len >= 2 and s[1] == ']') {
            return try ta.arrayType(try parseDisplayType(ta, s[2..]), null);
        }
        var i: usize = 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        if (i < s.len and s[i] == ']') {
            const len = try std.fmt.parseInt(usize, s[1..i], 10);
            return try ta.arrayType(try parseDisplayType(ta, s[i + 1 ..]), len);
        }
    }
    // Historical display used "int" / "byte".
    if (std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "number")) return TI64;
    if (std.mem.eql(u8, s, "byte")) return TU8;
    // `Enum.Variant` literal types (local names; module types use `::`).
    if (std.mem.indexOf(u8, s, "::") == null) {
        if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
            if (dot > 0 and dot + 1 < s.len) {
                return .{ .enum_lit = .{ .enum_name = s[0..dot], .variant = s[dot + 1 ..] } };
            }
        }
    }
    return namedType(s);
}

pub fn splitTopLevel(allocator: std.mem.Allocator, s: []const u8, sep: []const u8) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '[') depth += 1;
        if (c == ']') depth -= 1;
        if (depth == 0 and std.mem.startsWith(u8, s[i..], sep)) {
            try parts.append(allocator, std.mem.trim(u8, s[start..i], " \t"));
            i += sep.len;
            start = i;
            continue;
        }
        i += 1;
    }
    try parts.append(allocator, std.mem.trim(u8, s[start..], " \t"));
    return try parts.toOwnedSlice(allocator);
}
