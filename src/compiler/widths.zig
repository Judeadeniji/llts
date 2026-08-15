//! Shared integer / float width table (Zig-like).
//! Honest end-to-end: type IR, packed layout, `@as`, and `Value` tags agree.

const std = @import("std");

/// Operand for `OP_AS` and layout field kinds for numeric storage.
pub const Width = enum(u8) {
    i8 = 0,
    i16 = 1,
    i32 = 2,
    i64 = 3,
    u8 = 4,
    u16 = 5,
    u32 = 6,
    u64 = 7,
    f32 = 8,
    f64 = 9,

    pub fn size(self: Width) i32 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64 => 8,
        };
    }

    pub fn alignment(self: Width) i32 {
        return self.size();
    }

    pub fn name(self: Width) []const u8 {
        return switch (self) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .f32 => "f32",
            .f64 => "f64",
        };
    }

    pub fn isFloat(self: Width) bool {
        return self == .f32 or self == .f64;
    }

    pub fn isUnsigned(self: Width) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64 => true,
            else => false,
        };
    }
};

/// Resolve a type name to a width. Aliases: `int`/`number`→i64, `byte`→u8, `float`→f64.
pub fn fromName(name: []const u8) ?Width {
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "number"))
        return .i64;
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "byte")) return .u8;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "u64")) return .u64;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "float")) return .f64;
    return null;
}

/// Canonical display name (aliases normalize: int→i64, byte→u8, float→f64).
pub fn displayName(name: []const u8) ?[]const u8 {
    return if (fromName(name)) |w| w.name() else null;
}

pub fn i64Fits(width: Width, n: i64) bool {
    return switch (width) {
        .i8 => n >= std.math.minInt(i8) and n <= std.math.maxInt(i8),
        .i16 => n >= std.math.minInt(i16) and n <= std.math.maxInt(i16),
        .i32 => n >= std.math.minInt(i32) and n <= std.math.maxInt(i32),
        .i64 => true,
        .u8 => n >= 0 and n <= std.math.maxInt(u8),
        .u16 => n >= 0 and n <= std.math.maxInt(u16),
        .u32 => n >= 0 and n <= std.math.maxInt(u32),
        .u64 => n >= 0, // non-negative i64 always fits u64
        .f32, .f64 => true,
    };
}

const value_mod = @import("../bytecode/value.zig");
const Value = value_mod.Value;

pub fn valueAsI64(v: Value) ?i64 {
    return switch (v) {
        .i8 => |n| n,
        .i16 => |n| n,
        .i32 => |n| n,
        .i64 => |n| n,
        .u8 => |n| n,
        .u16 => |n| n,
        .u32 => |n| n,
        .u64 => |n| if (n <= std.math.maxInt(i64)) @intCast(n) else null,
        .bool => |b| @intFromBool(b),
        .f32 => |n| @intFromFloat(n),
        .f64 => |n| @intFromFloat(n),
        .ptr => |p| p,
        else => null,
    };
}

pub fn valueAsF64(v: Value) ?f64 {
    return switch (v) {
        .f64 => |n| n,
        .f32 => |n| n,
        .i8 => |n| @floatFromInt(n),
        .i16 => |n| @floatFromInt(n),
        .i32 => |n| @floatFromInt(n),
        .i64 => |n| @floatFromInt(n),
        .u8 => |n| @floatFromInt(n),
        .u16 => |n| @floatFromInt(n),
        .u32 => |n| @floatFromInt(n),
        .u64 => |n| @floatFromInt(n),
        .bool => |b| @floatFromInt(@intFromBool(b)),
        .ptr => |p| @floatFromInt(p),
        else => null,
    };
}

pub fn castValue(v: Value, to: Width) !Value {
    if (to.isFloat()) {
        const f = valueAsF64(v) orelse return error.TypeError;
        return switch (to) {
            .f32 => .{ .f32 = @floatCast(f) },
            .f64 => .{ .f64 = f },
            else => unreachable,
        };
    }
    const n = valueAsI64(v) orelse return error.TypeError;
    if (!i64Fits(to, n)) return error.OutOfRange;
    return switch (to) {
        .i8 => .{ .i8 = @intCast(n) },
        .i16 => .{ .i16 = @intCast(n) },
        .i32 => .{ .i32 = @intCast(n) },
        .i64 => .{ .i64 = n },
        .u8 => .{ .u8 = @intCast(n) },
        .u16 => .{ .u16 = @intCast(n) },
        .u32 => .{ .u32 = @intCast(n) },
        .u64 => .{ .u64 = @intCast(n) },
        else => unreachable,
    };
}

