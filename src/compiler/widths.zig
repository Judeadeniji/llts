//! Shared integer / float width table (Zig-like).
//! Honest end-to-end: type IR, packed layout, `@as`, and `Value` tags agree.

const std = @import("std");

/// Operand for `OP_AS`, `OP_ADD_TYPED` etc. and layout field kinds for numeric storage.
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
    /// 1-bit unsigned; `bool` / `boolean` alias this.
    u1 = 10,
    /// Signed integer of pointer width (= i64 on 64-bit platforms).
    isize = 11,
    /// Unsigned integer of pointer width (= u64 on 64-bit platforms).
    usize = 12,
    /// Float of platform width (= f64 on 64-bit platforms).
    fsize = 13,

    pub fn size(self: Width) i32 {
        return switch (self) {
            .u1, .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64, .isize, .usize, .fsize => 8,
        };
    }

    pub fn alignment(self: Width) i32 {
        return self.size();
    }

    pub fn name(self: Width) []const u8 {
        return switch (self) {
            .u1 => "u1",
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
            .isize => "isize",
            .usize => "usize",
            .fsize => "fsize",
        };
    }

    pub fn isFloat(self: Width) bool {
        return self == .f32 or self == .f64 or self == .fsize;
    }

    pub fn isUnsigned(self: Width) bool {
        return switch (self) {
            .u1, .u8, .u16, .u32, .u64, .usize => true,
            else => false,
        };
    }

    /// Resolve to the underlying fixed-width on the current platform (64-bit).
    pub fn concrete(self: Width) Width {
        return switch (self) {
            .isize => .i64,
            .usize => .u64,
            .fsize => .f64,
            else => self,
        };
    }
};

/// Resolve a type name to a width.
/// Aliases: `int`/`number`→i64, `byte`→u8, `float`→f64, `bool`/`boolean`→u1.
pub fn fromName(n: []const u8) ?Width {
    if (std.mem.eql(u8, n, "u1") or std.mem.eql(u8, n, "bool") or std.mem.eql(u8, n, "boolean"))
        return .u1;
    if (std.mem.eql(u8, n, "i8")) return .i8;
    if (std.mem.eql(u8, n, "i16")) return .i16;
    if (std.mem.eql(u8, n, "i32")) return .i32;
    if (std.mem.eql(u8, n, "i64") or std.mem.eql(u8, n, "int") or std.mem.eql(u8, n, "number"))
        return .i64;
    if (std.mem.eql(u8, n, "u8") or std.mem.eql(u8, n, "byte")) return .u8;
    if (std.mem.eql(u8, n, "u16")) return .u16;
    if (std.mem.eql(u8, n, "u32")) return .u32;
    if (std.mem.eql(u8, n, "u64")) return .u64;
    if (std.mem.eql(u8, n, "f32")) return .f32;
    if (std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "float")) return .f64;
    if (std.mem.eql(u8, n, "isize")) return .isize;
    if (std.mem.eql(u8, n, "usize")) return .usize;
    if (std.mem.eql(u8, n, "fsize")) return .fsize;
    return null;
}

/// Canonical display name (aliases normalize: int→i64, byte→u8, float→f64, bool→u1).
pub fn displayName(name: []const u8) ?[]const u8 {
    return if (fromName(name)) |w| w.name() else null;
}

pub fn i64Fits(width: Width, n: i64) bool {
    return switch (width.concrete()) {
        .u1 => n == 0 or n == 1,
        .i8 => n >= std.math.minInt(i8) and n <= std.math.maxInt(i8),
        .i16 => n >= std.math.minInt(i16) and n <= std.math.maxInt(i16),
        .i32 => n >= std.math.minInt(i32) and n <= std.math.maxInt(i32),
        .i64 => true,
        .u8 => n >= 0 and n <= std.math.maxInt(u8),
        .u16 => n >= 0 and n <= std.math.maxInt(u16),
        .u32 => n >= 0 and n <= std.math.maxInt(u32),
        .u64 => n >= 0, // non-negative i64 always fits u64
        .f32, .f64 => true,
        else => unreachable,
    };
}

const value_mod = @import("../bytecode/value.zig");
const Value = value_mod.Value;

pub fn valueAsI64(v: Value) ?i64 {
    return switch (v) {
        .u1 => |n| n,
        .i8 => |n| n,
        .i16 => |n| n,
        .i32 => |n| n,
        .i64 => |n| n,
        .u8 => |n| n,
        .u16 => |n| n,
        .u32 => |n| n,
        .u64 => |n| if (n <= std.math.maxInt(i64)) @intCast(n) else null,
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
        .u1 => |n| @floatFromInt(n),
        .i8 => |n| @floatFromInt(n),
        .i16 => |n| @floatFromInt(n),
        .i32 => |n| @floatFromInt(n),
        .i64 => |n| @floatFromInt(n),
        .u8 => |n| @floatFromInt(n),
        .u16 => |n| @floatFromInt(n),
        .u32 => |n| @floatFromInt(n),
        .u64 => |n| @floatFromInt(n),
        .ptr => |p| @floatFromInt(p),
        else => null,
    };
}

/// Returns true when `from` can be implicitly widened to `to` without
/// data loss: same signedness family with a strictly larger bit-width,
/// or any integer widening into a float.
pub fn isWidening(from: Width, to: Width) bool {
    if (from == to) return false;
    // Normalise platform-width aliases so isize/i64 etc. compare as equal rank.
    const cf = from.concrete();
    const ct = to.concrete();
    if (cf == ct) return false; // isize↔i64, usize↔u64, fsize↔f64 — same rank
    // Integer → float is always a widening.
    if (!cf.isFloat() and ct.isFloat()) return true;
    // Float widening: f32 → f64.
    if (cf == .f32 and ct == .f64) return true;
    // Signed integer family: i8 ⊆ i16 ⊆ i32 ⊆ i64.
    const signed_rank: ?u8 = switch (cf) {
        .i8 => 0, .i16 => 1, .i32 => 2, .i64 => 3, else => null,
    };
    const signed_rank_to: ?u8 = switch (ct) {
        .i8 => 0, .i16 => 1, .i32 => 2, .i64 => 3, else => null,
    };
    if (signed_rank != null and signed_rank_to != null)
        return signed_rank.? < signed_rank_to.?;
    // Unsigned integer family: u1 ⊆ u8 ⊆ u16 ⊆ u32 ⊆ u64.
    const unsigned_rank: ?u8 = switch (cf) {
        .u1 => 0, .u8 => 1, .u16 => 2, .u32 => 3, .u64 => 4, else => null,
    };
    const unsigned_rank_to: ?u8 = switch (ct) {
        .u1 => 0, .u8 => 1, .u16 => 2, .u32 => 3, .u64 => 4, else => null,
    };
    if (unsigned_rank != null and unsigned_rank_to != null)
        return unsigned_rank.? < unsigned_rank_to.?;
    return false;
}

/// Returns true when `from` can be implicitly narrowed to `to` within the
/// same signedness family (or float→int / f64→f32).  Data loss is possible,
/// so callers should emit a warning rather than silently accepting.
pub fn isNarrowing(from: Width, to: Width) bool {
    return isWidening(to, from);
}

pub fn castValue(v: Value, to: Width) !Value {
    if (to.isFloat()) {
        const f = valueAsF64(v) orelse return error.TypeError;
        return switch (to.concrete()) {
            .f32 => .{ .f32 = @floatCast(f) },
            else => .{ .f64 = f }, // f64, fsize
        };
    }
    const n = valueAsI64(v) orelse return error.TypeError;
    if (!i64Fits(to.concrete(), n)) return error.OutOfRange;
    return switch (to.concrete()) {
        .u1 => .{ .u1 = @intCast(n) },
        .i8 => .{ .i8 = @intCast(n) },
        .i16 => .{ .i16 = @intCast(n) },
        .i32 => .{ .i32 = @intCast(n) },
        .i64 => .{ .i64 = n }, // also isize
        .u8 => .{ .u8 = @intCast(n) },
        .u16 => .{ .u16 = @intCast(n) },
        .u32 => .{ .u32 = @intCast(n) },
        .u64 => .{ .u64 = @intCast(n) }, // also usize
        else => unreachable,
    };
}

/// Wrap an i64 arithmetic result to the target width with wrapping (two's
/// complement) semantics — no bounds error.  Used by `OP_ADD_TYPED` etc.
pub fn wrapToWidth(n: i64, to: Width) Value {
    return switch (to.concrete()) {
        .u1  => .{ .u1  = @truncate(@as(u64, @bitCast(n))) },
        .i8  => .{ .i8  = @truncate(n) },
        .i16 => .{ .i16 = @truncate(n) },
        .i32 => .{ .i32 = @truncate(n) },
        .i64 => .{ .i64 = n },
        .u8  => .{ .u8  = @truncate(@as(u64, @bitCast(n))) },
        .u16 => .{ .u16 = @truncate(@as(u64, @bitCast(n))) },
        .u32 => .{ .u32 = @truncate(@as(u64, @bitCast(n))) },
        .u64 => .{ .u64 = @bitCast(n) },
        else => unreachable,
    };
}

