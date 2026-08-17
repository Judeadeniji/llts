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
    isize = 18,
    usize = 19,
    fsize = 20,
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
    isize,
    usize,
    fsize,
    null,
    error_,
    unknown,
    never,
    struct_: []const u8,
    enum_: []const u8,
    /// Singleton enum variant used as a type (`ExprKind.Literal`).
    enum_lit: struct { enum_name: []const u8, variant: []const u8 },
    /// String / int / bool singleton types (`"a"`, `0`, `true`).
    str_lit: []const u8,
    int_lit: i64,
    bool_lit: bool,
    array: struct { elem: *Type, length: ?usize },
    /// `[T, U, …]` fixed heterogeneous product (runtime: value array).
    tuple: []Type,
    ptr: *Type,
    union_: []Type,
    /// Go-style distinct `@type Name = T` (aliases unwrap and never appear here).
    defined: struct { name: []const u8, underlying: *Type },
    /// `@func(T, U): R` — first-class function type (structural).
    func: struct { params: []Type, ret: *Type, variadic: bool },
    /// `{ field: T; … }` anonymous object shape (structural).
    shape: []ShapeField,
    /// `@error Name` closed error set.
    error_set: []const u8,
    /// Singleton error member used as a type (`IoError.NotFound`).
    error_lit: struct { set_name: []const u8, variant: []const u8 },
};

pub const ShapeField = struct {
    name: []const u8,
    ty: Type,
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
pub const TISize: Type = .{ .isize = {} };
pub const TUSize: Type = .{ .usize = {} };
pub const TFSize: Type = .{ .fsize = {} };
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

    pub fn tupleType(self: TypeAlloc, elems: []const Type) !Type {
        const es = try self.allocator.alloc(Type, elems.len);
        @memcpy(es, elems);
        return .{ .tuple = es };
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

    pub fn funcType(self: TypeAlloc, params: []const Type, ret: Type, variadic: bool) !Type {
        const ps = try self.allocator.alloc(Type, params.len);
        @memcpy(ps, params);
        const rp = try self.allocType(ret);
        return .{ .func = .{ .params = ps, .ret = rp, .variadic = variadic } };
    }

    pub fn shapeType(self: TypeAlloc, fields: []const ShapeField) !Type {
        const fs = try self.allocator.alloc(ShapeField, fields.len);
        @memcpy(fs, fields);
        return .{ .shape = fs };
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
        .isize => TISize,
        .usize => TUSize,
        .fsize => TFSize,
    };
}

pub fn widthOf(t: Type) ?widths.Width {
    return switch (t) {
        .defined => |d| widthOf(d.underlying.*),
        .int_lit => .i64,
        .bool_lit => .u1,
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
        .isize => .isize,
        .usize => .usize,
        .fsize => .fsize,
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
        .u1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .isize, .usize, .fsize => try allocator.dupe(u8, displayWidth(t)),
        .null => try allocator.dupe(u8, "null"),
        .error_ => try allocator.dupe(u8, "error"),
        .unknown => try allocator.dupe(u8, "unknown"),
        .never => try allocator.dupe(u8, "never"),
        .struct_ => |n| try allocator.dupe(u8, n),
        .enum_ => |n| try allocator.dupe(u8, n),
        .enum_lit => |e| try std.fmt.allocPrint(allocator, "{s}.{s}", .{ e.enum_name, e.variant }),
        .str_lit => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .int_lit => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .bool_lit => |b| try allocator.dupe(u8, if (b) "true" else "false"),
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
        .tuple => |elems| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            defer {
                for (parts.items) |p| allocator.free(p);
                parts.deinit(allocator);
            }
            for (elems) |e| try parts.append(allocator, try displayTypeAlloc(allocator, e));
            var total: usize = 2; // []
            for (parts.items, 0..) |p, i| {
                total += p.len;
                if (i > 0) total += 2;
            }
            const out = try allocator.alloc(u8, total);
            out[0] = '[';
            var offset: usize = 1;
            for (parts.items, 0..) |p, i| {
                if (i > 0) {
                    @memcpy(out[offset .. offset + 2], ", ");
                    offset += 2;
                }
                @memcpy(out[offset .. offset + p.len], p);
                offset += p.len;
            }
            out[offset] = ']';
            break :blk out;
        },
        .ptr => |p| blk: {
            const inner = try displayTypeAlloc(allocator, p.*);
            defer allocator.free(inner);
            break :blk try std.fmt.allocPrint(allocator, "*{s}", .{inner});
        },
        .func => |f| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            defer {
                for (parts.items) |p| allocator.free(p);
                parts.deinit(allocator);
            }
            for (f.params, 0..) |p, i| {
                const d = try displayTypeAlloc(allocator, p);
                if (f.variadic and i + 1 == f.params.len) {
                    const with_dots = try std.fmt.allocPrint(allocator, "...{s}", .{d});
                    allocator.free(d);
                    try parts.append(allocator, with_dots);
                } else {
                    try parts.append(allocator, d);
                }
            }
            var param_total: usize = 0;
            for (parts.items, 0..) |p, i| {
                param_total += p.len;
                if (i > 0) param_total += 2;
            }
            const params_s = try allocator.alloc(u8, param_total);
            defer allocator.free(params_s);
            var poff: usize = 0;
            for (parts.items, 0..) |p, i| {
                if (i > 0) {
                    @memcpy(params_s[poff .. poff + 2], ", ");
                    poff += 2;
                }
                @memcpy(params_s[poff .. poff + p.len], p);
                poff += p.len;
            }
            const ret = try displayTypeAlloc(allocator, f.ret.*);
            defer allocator.free(ret);
            break :blk try std.fmt.allocPrint(allocator, "@func({s}): {s}", .{ params_s, ret });
        },
        .shape => |fields| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            defer {
                for (parts.items) |p| allocator.free(p);
                parts.deinit(allocator);
            }
            for (fields) |f| {
                const ty = try displayTypeAlloc(allocator, f.ty);
                defer allocator.free(ty);
                try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ f.name, ty }));
            }
            var total: usize = 2; // {}
            for (parts.items, 0..) |p, i| {
                total += p.len;
                if (i > 0) total += 2; // "; "
            }
            const out = try allocator.alloc(u8, total);
            out[0] = '{';
            var offset: usize = 1;
            for (parts.items, 0..) |p, i| {
                if (i > 0) {
                    @memcpy(out[offset .. offset + 2], "; ");
                    offset += 2;
                }
                @memcpy(out[offset .. offset + p.len], p);
                offset += p.len;
            }
            out[offset] = '}';
            break :blk out;
        },
        .error_set => |n| try allocator.dupe(u8, n),
        .error_lit => |e| try std.fmt.allocPrint(allocator, "{s}.{s}", .{ e.set_name, e.variant }),
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
        .u1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .isize, .usize, .fsize => displayWidth(t),
        .null => "null",
        .error_ => "error",
        .unknown => "unknown",
        .never => "never",
        .struct_ => |n| n,
        .enum_ => |n| n,
        .enum_lit => null,
        .str_lit, .int_lit, .bool_lit => null,
        .array => |a| if (a.elem.* == .u8 and a.length == null) "[]byte" else null,
        .ptr, .union_, .func, .tuple, .shape => null,
        .error_set => |n| n,
        .error_lit => null,
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
        .str_lit => |s| b == .str_lit and std.mem.eql(u8, s, b.str_lit),
        .int_lit => |n| b == .int_lit and n == b.int_lit,
        .bool_lit => |v| b == .bool_lit and v == b.bool_lit,
        .array => |aa| b == .array and aa.length == b.array.length and typeEquals(aa.elem.*, b.array.elem.*),
        .tuple => |ae| blk: {
            if (b != .tuple) break :blk false;
            const be = b.tuple;
            if (ae.len != be.len) break :blk false;
            for (ae, be) |x, y| {
                if (!typeEquals(x, y)) break :blk false;
            }
            break :blk true;
        },
        .ptr => |p| b == .ptr and typeEquals(p.*, b.ptr.*),
        .func => |fa| blk: {
            if (b != .func) break :blk false;
            const fb = b.func;
            if (fa.variadic != fb.variadic) break :blk false;
            if (fa.params.len != fb.params.len) break :blk false;
            if (!typeEquals(fa.ret.*, fb.ret.*)) break :blk false;
            for (fa.params, fb.params) |pa, pb| {
                if (!typeEquals(pa, pb)) break :blk false;
            }
            break :blk true;
        },
        .shape => |fa| blk: {
            if (b != .shape) break :blk false;
            const fb = b.shape;
            if (fa.len != fb.len) break :blk false;
            for (fa, fb) |a_f, b_f| {
                if (!std.mem.eql(u8, a_f.name, b_f.name)) break :blk false;
                if (!typeEquals(a_f.ty, b_f.ty)) break :blk false;
            }
            break :blk true;
        },
        .error_set => |n| b == .error_set and std.mem.eql(u8, n, b.error_set),
        .error_lit => |e| b == .error_lit and std.mem.eql(u8, e.set_name, b.error_lit.set_name) and std.mem.eql(u8, e.variant, b.error_lit.variant),
        .defined => |d| (b == .defined and std.mem.eql(u8, d.name, b.defined.name)) or typeEquals(d.underlying.*, b),
        .u1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .isize, .usize, .fsize, .null, .error_, .unknown, .never => true,
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
        // `@type Name = {…}` layouts are registered under Name.
        .defined => |d| if (d.underlying.* == .shape) d.name else structNameOf(d.underlying.*),
        else => if (optionalPayload(t)) |p| structNameOf(p) else null,
    };
}

/// Shape field list, peeling `@type` wrappers.
pub fn shapeFieldsOf(t: Type) ?[]ShapeField {
    return switch (peelDefined(t)) {
        .shape => |f| f,
        else => if (optionalPayload(t)) |p| shapeFieldsOf(p) else null,
    };
}

/// `a ⊑ b` — assignability. Prefer switching on the *expected* type (`b`).
pub fn isSubtype(a: Type, b: Type) bool {
    // Hot paths: bottom / top / identical.
    switch (a) {
        .never, .unknown => return true,
        else => {},
    }
    if (b == .unknown) return true;
    if (typeEquals(a, b)) return true;

    return switch (b) {
        // Distinct `@type Name`: coerce *into* Name from underlying; Name values do not unwrap.
        .defined => |d| switch (a) {
            .defined => |ad| std.mem.eql(u8, ad.name, d.name),
            else => isSubtype(a, d.underlying.*),
        },
        .union_ => |arms| subtypeOfAny(a, arms),
        .array => |ba| switch (a) {
            .array => arraySubtype(a, b),
            .str_lit => |s| ba.elem.* == .u8 and (ba.length == null or ba.length.? == s.len),
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .tuple => |be| switch (a) {
            .tuple => |ae| blk: {
                if (ae.len != be.len) break :blk false;
                for (ae, be) |x, y| {
                    if (!isSubtype(x, y)) break :blk false;
                }
                break :blk true;
            },
            // Homogeneous `[N]T` may fill a tuple of length N.
            .array => |aa| blk: {
                if (aa.length == null or aa.length.? != be.len) break :blk false;
                for (be) |bt| {
                    if (!isSubtype(aa.elem.*, bt)) break :blk false;
                }
                break :blk true;
            },
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .ptr => |bp| switch (a) {
            .ptr => |ap| typeEquals(ap.*, bp.*),
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .func => |bf| switch (a) {
            .func => |af| funcSubtype(af, bf),
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .shape => |bf| switch (a) {
            .shape => |af| shapeSubtype(af, bf),
            // Distinct `@type` values may satisfy a structural expected shape.
            .defined => |d| isSubtype(d.underlying.*, b),
            .union_ => |arms| subtypeAll(arms, b),
            else => false,
        },
        .error_set => |ename| switch (a) {
            .error_set => |an| std.mem.eql(u8, an, ename),
            .error_lit => |e| std.mem.eql(u8, e.set_name, ename),
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .error_lit => |el| switch (a) {
            .error_lit => |al| std.mem.eql(u8, al.set_name, el.set_name) and std.mem.eql(u8, al.variant, el.variant),
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .error_ => switch (a) {
            .error_, .error_set, .error_lit => true,
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .enum_ => |ename| switch (a) {
            .enum_lit => |e| std.mem.eql(u8, e.enum_name, ename),
            .i64 => true,
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .i64 => switch (a) {
            .enum_, .enum_lit, .int_lit => true,
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        .u1 => switch (a) {
            .bool_lit => true,
            .union_ => |arms| subtypeAll(arms, b),
            .defined => false,
            else => false,
        },
        // Widths and everything else: only union/literal widenings left.
        else => switch (a) {
            .defined => false,
            .union_ => |arms| subtypeAll(arms, b),
            .str_lit => isByteSlice(b),
            .int_lit => isInteger(b),
            .bool_lit => false, // only ⊑ u1, handled above
            .enum_lit => false,
            else => false,
        },
    };
}

fn subtypeOfAny(a: Type, arms: []const Type) bool {
    for (arms) |arm| {
        if (isSubtype(a, arm)) return true;
    }
    return false;
}

fn subtypeAll(arms: []const Type, b: Type) bool {
    for (arms) |arm| {
        if (!isSubtype(arm, b)) return false;
    }
    return true;
}

fn arraySubtype(a: Type, b: Type) bool {
    const aa = a.array;
    const ba = b.array;
    if (!isSubtype(aa.elem.*, ba.elem.*)) return false;
    if (ba.length == null) return true;
    if (aa.length == null) return false;
    return aa.length.? == ba.length.?;
}

/// `fn(A)→R` ⊑ `fn(B)→S` when params are contravariant and return is covariant.
fn funcSubtype(a: anytype, b: anytype) bool {
    if (a.variadic != b.variadic) return false;
    if (a.params.len != b.params.len) return false;
    if (!isSubtype(a.ret.*, b.ret.*)) return false;
    for (a.params, b.params) |ap, bp| {
        if (!isSubtype(bp, ap)) return false;
    }
    return true;
}

/// Structural: got has every expected field with a subtype (extra fields OK).
fn shapeSubtype(got: []const ShapeField, expected: []const ShapeField) bool {
    for (expected) |ef| {
        var found = false;
        for (got) |gf| {
            if (std.mem.eql(u8, gf.name, ef.name)) {
                if (!isSubtype(gf.ty, ef.ty)) return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn involvesUnknown(t: Type) bool {
    return switch (t) {
        .unknown => true,
        .array => |a| involvesUnknown(a.elem.*),
        .tuple => |elems| blk: {
            for (elems) |e| {
                if (involvesUnknown(e)) break :blk true;
            }
            break :blk false;
        },
        .ptr => |p| involvesUnknown(p.*),
        .func => |f| blk: {
            if (involvesUnknown(f.ret.*)) break :blk true;
            for (f.params) |p| {
                if (involvesUnknown(p)) break :blk true;
            }
            break :blk false;
        },
        .shape => |fields| blk: {
            for (fields) |f| {
                if (involvesUnknown(f.ty)) break :blk true;
            }
            break :blk false;
        },
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

pub fn isErrorArm(t: Type) bool {
    return switch (peelDefined(t)) {
        .error_, .error_set, .error_lit => true,
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (isErrorArm(arm)) break :blk true;
            }
            break :blk false;
        },
        else => if (optionalPayload(t)) |p| isErrorArm(p) else false,
    };
}

pub fn isErrorUnion(t: Type) bool {
    return switch (t) {
        .error_, .error_set, .error_lit => true,
        .defined => |d| isErrorUnion(d.underlying.*),
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (isErrorArm(arm)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn allowsError(t: Type) bool {
    return switch (t) {
        .error_, .error_set, .error_lit, .unknown => true,
        .defined => |d| allowsError(d.underlying.*),
        .union_ => |arms| blk: {
            for (arms) |arm| {
                if (isErrorArm(arm)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn unwrapError(ta: TypeAlloc, t: Type) !Type {
    return switch (t) {
        .error_, .error_set, .error_lit => TNever,
        .defined => |d| try unwrapError(ta, d.underlying.*),
        .union_ => |arms| blk: {
            var kept: std.ArrayList(Type) = .empty;
            defer kept.deinit(ta.allocator);
            for (arms) |arm| {
                if (!isErrorArm(arm)) try kept.append(ta.allocator, arm);
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

pub fn isString(t: Type) bool {
    const p = peelDefined(t);
    if (p == .str_lit) return true;
    if (p == .struct_) return std.mem.eql(u8, p.struct_, "string");
    return false;
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
        .isize => .isize,
        .usize => .usize,
        .fsize => .fsize,
        .null => .null,
        .error_ => .error_,
        .error_set, .error_lit => .error_,
        .array => |a| if (a.elem.* == .u8) .string else .array,
        .struct_, .shape => .struct_,
        .enum_, .enum_lit => .i64,
        .int_lit => .i64,
        .bool_lit => .u1,
        .str_lit => .string,
        .union_ => |u| if (isErrorUnion(.{ .union_ = u })) .error_union else null,
        else => null,
    };
}

/// Split `@func(…): R` into the params interior and optional return display.
pub fn splitFuncDisplay(s: []const u8) !?struct { params: []const u8, ret: ?[]const u8 } {
    if (!std.mem.startsWith(u8, s, "@func(")) return null;
    const open = "@func(".len - 1; // index of '('
    var depth: i32 = 0;
    var close: ?usize = null;
    var i: usize = open;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const end = close orelse return error.CompileError;
    const params = s[open + 1 .. end];
    var rest = std.mem.trim(u8, s[end + 1 ..], " \t");
    var ret: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, ":")) {
        ret = std.mem.trim(u8, rest[1..], " \t");
    }
    return .{ .params = params, .ret = ret };
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
        var depth: i32 = 0;
        var close: ?usize = null;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '[') depth += 1;
            if (c == ']') {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            }
        }
        const end = close orelse return error.CompileError;
        const interior = s[1..end];
        const rest = std.mem.trim(u8, s[end + 1 ..], " \t");
        if (rest.len > 0) {
            // `[N]T`
            const len = try std.fmt.parseInt(usize, interior, 10);
            return try ta.arrayType(try parseDisplayType(ta, rest), len);
        }
        // `[T, U, …]` tuple (including 1-tuples)
        const parts = try splitTopLevel(ta.allocator, interior, ", ");
        defer ta.allocator.free(parts);
        var elems: std.ArrayList(Type) = .empty;
        defer elems.deinit(ta.allocator);
        for (parts) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            try elems.append(ta.allocator, try parseDisplayType(ta, p));
        }
        return try ta.tupleType(elems.items);
    }
    if (s.len > 0 and s[0] == '{') {
        if (s[s.len - 1] != '}') return error.CompileError;
        const interior = s[1 .. s.len - 1];
        const parts = try splitTopLevel(ta.allocator, interior, ";");
        defer ta.allocator.free(parts);
        var fields: std.ArrayList(ShapeField) = .empty;
        defer fields.deinit(ta.allocator);
        for (parts) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            const colon = blk: {
                var depth: i32 = 0;
                var i: usize = 0;
                while (i < p.len) : (i += 1) {
                    const c = p[i];
                    if (c == '[' or c == '(' or c == '{') depth += 1;
                    if (c == ']' or c == ')' or c == '}') depth -= 1;
                    if (depth == 0 and c == ':') break :blk i;
                }
                return error.CompileError;
            };
            const fname = std.mem.trim(u8, p[0..colon], " \t");
            const fty = std.mem.trim(u8, p[colon + 1 ..], " \t");
            if (fname.len == 0 or fty.len == 0) return error.CompileError;
            const name_owned = try ta.allocator.dupe(u8, fname);
            try fields.append(ta.allocator, .{
                .name = name_owned,
                .ty = try parseDisplayType(ta, fty),
            });
        }
        return try ta.shapeType(fields.items);
    }
    if (try splitFuncDisplay(s)) |parts| {
        var params: std.ArrayList(Type) = .empty;
        defer params.deinit(ta.allocator);
        var variadic = false;
        if (parts.params.len > 0) {
            const param_parts = try splitTopLevel(ta.allocator, parts.params, ", ");
            defer ta.allocator.free(param_parts);
            for (param_parts, 0..) |part, pi| {
                var p = std.mem.trim(u8, part, " \t");
                if (std.mem.startsWith(u8, p, "...")) {
                    if (pi + 1 != param_parts.len) return error.CompileError;
                    variadic = true;
                    p = std.mem.trim(u8, p[3..], " \t");
                }
                try params.append(ta.allocator, try parseDisplayType(ta, p));
            }
        }
        const ret = if (parts.ret) |r| try parseDisplayType(ta, r) else TUnknown;
        return try ta.funcType(params.items, ret, variadic);
    }
    // Historical display used "int" / "byte".
    if (std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "number")) return TI64;
    if (std.mem.eql(u8, s, "byte")) return TU8;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return .{ .str_lit = s[1 .. s.len - 1] };
    }
    if (std.mem.eql(u8, s, "true")) return .{ .bool_lit = true };
    if (std.mem.eql(u8, s, "false")) return .{ .bool_lit = false };
    if (s.len > 0 and (s[0] == '-' or (s[0] >= '0' and s[0] <= '9'))) {
        if (std.mem.indexOfScalar(u8, s, '.') == null) {
            if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .int_lit = n } else |_| {}
        }
    }
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
        if (c == '[' or c == '(' or c == '{') depth += 1;
        if (c == ']' or c == ')' or c == '}') depth -= 1;
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
