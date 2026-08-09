const std = @import("std");

pub const TypeTag = enum(u8) {
    int = 1,
    bool = 2,
    string = 3,
    null = 4,
    error_ = 5,
    array = 6,
    struct_ = 7,
    error_union = 8,
    byte = 9,
};

pub const Type = union(enum) {
    int,
    bool,
    byte,
    null,
    error_,
    unknown,
    never,
    struct_: []const u8,
    array: struct { elem: *Type, length: ?usize },
    union_: []Type,
};

pub const TUnknown: Type = .{ .unknown = {} };
pub const TInt: Type = .{ .int = {} };
pub const TBool: Type = .{ .bool = {} };
pub const TByte: Type = .{ .byte = {} };
pub const TNull: Type = .{ .null = {} };
pub const TError: Type = .{ .error_ = {} };
pub const TNever: Type = .{ .never = {} };

var byte_elem: Type = .{ .byte = {} };
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
        // Dedup by display key (best-effort without owned strings)
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
};

pub fn namedType(name: []const u8) Type {
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "i32") or std.mem.eql(u8, name, "number"))
        return TInt;
    if (std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "boolean")) return TBool;
    if (std.mem.eql(u8, name, "byte") or std.mem.eql(u8, name, "u8")) return TByte;
    if (std.mem.eql(u8, name, "null")) return TNull;
    if (std.mem.eql(u8, name, "error")) return TError;
    if (std.mem.eql(u8, name, "string")) return TString;
    if (std.mem.eql(u8, name, "unknown")) return TUnknown;
    return .{ .struct_ = name };
}

/// Builtin / primitive type names (not structs).
pub fn isBuiltinTypeName(name: []const u8) bool {
    return switch (namedType(name)) {
        .struct_ => false,
        else => true,
    };
}

pub fn displayTypeAlloc(allocator: std.mem.Allocator, t: Type) ![]const u8 {
    return switch (t) {
        .int => try allocator.dupe(u8, "int"),
        .bool => try allocator.dupe(u8, "bool"),
        .byte => try allocator.dupe(u8, "byte"),
        .null => try allocator.dupe(u8, "null"),
        .error_ => try allocator.dupe(u8, "error"),
        .unknown => try allocator.dupe(u8, "unknown"),
        .never => try allocator.dupe(u8, "never"),
        .struct_ => |n| try allocator.dupe(u8, n),
        .array => |a| blk: {
            const elem = try displayTypeAlloc(allocator, a.elem.*);
            defer allocator.free(elem);
            if (a.length) |len| {
                break :blk try std.fmt.allocPrint(allocator, "[{d}]{s}", .{ len, elem });
            }
            break :blk try std.fmt.allocPrint(allocator, "[]{s}", .{elem});
        },
        .union_ => |arms| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            defer {
                for (parts.items) |p| allocator.free(p);
                parts.deinit(allocator);
            }
            for (arms) |arm| {
                try parts.append(allocator, try displayTypeAlloc(allocator, arm));
            }
            var total: usize = 0;
            for (parts.items, 0..) |p, i| {
                total += p.len;
                if (i > 0) total += 3; // " | "
            }
            var out = try allocator.alloc(u8, total);
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

/// Static display for simple types (no allocation). Nested arrays/unions return null.
pub fn displayTypeSimple(t: Type) ?[]const u8 {
    return switch (t) {
        .int => "int",
        .bool => "bool",
        .byte => "byte",
        .null => "null",
        .error_ => "error",
        .unknown => "unknown",
        .never => "never",
        .struct_ => |n| n,
        .array => |a| if (a.elem.* == .byte and a.length == null) "[]byte" else null,
        .union_ => null,
    };
}

/// Back-compat: prefer simple; callers needing full display should use displayTypeAlloc.
pub fn displayType(t: Type) []const u8 {
    return displayTypeSimple(t) orelse "unknown";
}

pub fn typeEquals(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        if (a == .union_ or b == .union_) {
            // Fall through to structural compare via tags only when both unions handled below
        } else return false;
    }
    return switch (a) {
        .struct_ => |n| b == .struct_ and std.mem.eql(u8, n, b.struct_),
        .array => |aa| b == .array and aa.length == b.array.length and typeEquals(aa.elem.*, b.array.elem.*),
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
        .int, .bool, .byte, .null, .error_, .unknown, .never => std.meta.activeTag(a) == std.meta.activeTag(b),
    };
}

pub fn isSubtype(a: Type, b: Type) bool {
    if (a == .never) return true;
    if (b == .unknown or a == .unknown) return true;
    if (typeEquals(a, b)) return true;

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
    return false;
}

pub fn involvesUnknown(t: Type) bool {
    return switch (t) {
        .unknown => true,
        .array => |a| involvesUnknown(a.elem.*),
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
    if (t != .union_) return false;
    for (t.union_) |arm| {
        if (arm == .error_) return true;
    }
    return false;
}

pub fn unwrapError(ta: TypeAlloc, t: Type) !Type {
    if (t != .union_) return t;
    var rest: std.ArrayList(Type) = .empty;
    defer rest.deinit(ta.allocator);
    for (t.union_) |arm| {
        if (arm != .error_) try rest.append(ta.allocator, arm);
    }
    if (rest.items.len == 0) return TError;
    if (rest.items.len == 1) return rest.items[0];
    return try ta.unionType(rest.items);
}

pub fn allowsError(t: Type) bool {
    return switch (t) {
        .error_, .unknown => true,
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (arm == .error_) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn isByteSlice(t: Type) bool {
    return t == .array and t.array.elem.* == .byte;
}

pub fn typeTag(t: Type) ?TypeTag {
    return switch (t) {
        .int => .int,
        .bool => .bool,
        .byte => .byte,
        .null => .null,
        .error_ => .error_,
        .array => |a| if (a.elem.* == .byte) .string else .array,
        .struct_ => .struct_,
        .union_ => if (isErrorUnion(t)) .error_union else null,
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
    if (s.len > 0 and s[0] == '[') {
        if (s.len >= 2 and s[1] == ']') {
            return try ta.arrayType(try parseDisplayType(ta, s[2..]), null);
        }
        var i: usize = 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        if (i < s.len and s[i] == ']' and i > 1) {
            const len = try std.fmt.parseInt(usize, s[1..i], 10);
            return try ta.arrayType(try parseDisplayType(ta, s[i + 1 ..]), len);
        }
        return namedType(s);
    }
    return namedType(s);
}

fn splitTopLevel(allocator: std.mem.Allocator, s: []const u8, sep: []const u8) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '[') depth += 1 else if (ch == ']') depth -= 1 else if (depth == 0 and std.mem.startsWith(u8, s[i..], sep)) {
            const part = std.mem.trim(u8, s[start..i], " \t");
            if (part.len > 0) try parts.append(allocator, part);
            i += sep.len - 1;
            start = i + 1;
        }
    }
    const last = std.mem.trim(u8, s[start..], " \t");
    if (last.len > 0) try parts.append(allocator, last);
    return try parts.toOwnedSlice(allocator);
}
