//! Shared integer / float width table (Zig-like).
//! Canonical definitions live in the native runtime (`src/runtime/widths.zig`);
//! this module re-exports them plus the `Value`-dependent helpers so every
//! existing `widths.X` import keeps working. Honest end-to-end: type IR,
//! packed layout, `@as`, and `Value` tags agree.

const std = @import("std");
const rt_widths = @import("../runtime/widths.zig");

pub const Width = rt_widths.Width;
pub const fromName = rt_widths.fromName;
pub const displayName = rt_widths.displayName;
pub const i64Fits = rt_widths.i64Fits;
pub const i128Fits = rt_widths.i128Fits;
pub const isWidening = rt_widths.isWidening;
pub const isNarrowing = rt_widths.isNarrowing;

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
        .u1 => .{ .u1 = @truncate(@as(u64, @bitCast(n))) },
        .i8 => .{ .i8 = @truncate(n) },
        .i16 => .{ .i16 = @truncate(n) },
        .i32 => .{ .i32 = @truncate(n) },
        .i64 => .{ .i64 = n },
        .u8 => .{ .u8 = @truncate(@as(u64, @bitCast(n))) },
        .u16 => .{ .u16 = @truncate(@as(u64, @bitCast(n))) },
        .u32 => .{ .u32 = @truncate(@as(u64, @bitCast(n))) },
        .u64 => .{ .u64 = @bitCast(n) },
        else => unreachable,
    };
}
