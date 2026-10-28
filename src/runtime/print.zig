//! Print primitives — native counterpart to `src/vm/builtins/print.zig`,
//! with VM-exact formats: space-joined args + trailing newline, unbuffered
//! stdout writes, f64 integer-exact special case, printable byte rules.
//!
//! Strings (`[]const u8`) render raw; mutable byte buffers (`[]u8`) apply the
//! printable-check rules (raw when every byte is 32..126 / `\n` / `\t`,
//! otherwise `[97, 98]`); integer arrays use the same printable heuristic the
//! VM's `writeArray` applies.

const std = @import("std");
const io = @import("io.zig");
const Context = @import("context.zig").Context;
const err_mod = @import("err.zig");

/// Wrapper used by emitted `print(@addrOf(x))` to render raw hex pointers.
pub const Addr = struct { value: usize };

pub fn writeNull(out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, "null");
}

pub fn writeBool(out: *std.ArrayList(u8), alloc: std.mem.Allocator, b: bool) !void {
    try out.appendSlice(alloc, if (b) "true" else "false");
}

pub fn writeInt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, n: anytype) !void {
    var tmp: [40]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
    try out.appendSlice(alloc, s);
}

/// f32 formats directly via `{d}` (VM parity — no integer special case).
pub fn writeFloat32(out: *std.ArrayList(u8), alloc: std.mem.Allocator, n: f32) !void {
    var tmp: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
    try out.appendSlice(alloc, s);
}

/// f64: prefer integer formatting when exact (math.ceil etc. return ints;
/// pi/e stay float) — VM writeValue f64-arm logic, byte for byte.
pub fn writeFloat(out: *std.ArrayList(u8), alloc: std.mem.Allocator, n: f64) !void {
    var tmp: [64]u8 = undefined;
    if (n == @floor(n) and
        n >= @as(f64, @floatFromInt(std.math.minInt(i32))) and
        n <= @as(f64, @floatFromInt(std.math.maxInt(i32))))
    {
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{@as(i32, @intFromFloat(n))});
        try out.appendSlice(alloc, s);
    } else {
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
        try out.appendSlice(alloc, s);
    }
}

/// Strings print raw (`writeValue` `.slice`/`.name` parity).
pub fn writeStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(alloc, s);
}

/// Byte buffers: printable span prints raw, otherwise decimal list
/// (`writePackedBytes` parity). Empty prints nothing.
pub fn writeBytes(out: *std.ArrayList(u8), alloc: std.mem.Allocator, data: []const u8) !void {
    if (data.len == 0) return;
    var printable = true;
    for (data) |ch| {
        if (ch < 32 or ch > 126) {
            if (ch != '\n' and ch != '\t') {
                printable = false;
                break;
            }
        }
    }
    if (printable) {
        try out.appendSlice(alloc, data);
        return;
    }
    try out.append(alloc, '[');
    for (data, 0..) |ch, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try writeInt(out, alloc, ch);
    }
    try out.append(alloc, ']');
}

/// `Error: <code>` with ` — <payload>` when present (VM error-arm parity).
pub fn writeError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, e: err_mod.Error) !void {
    try out.appendSlice(alloc, "Error: ");
    try out.appendSlice(alloc, e.code);
    switch (e.payload) {
        .none => {},
        .int => |n| {
            try out.appendSlice(alloc, " — ");
            try writeInt(out, alloc, n);
        },
        .float => |n| {
            try out.appendSlice(alloc, " — ");
            try writeFloat(out, alloc, n);
        },
        .boolean => |b| {
            try out.appendSlice(alloc, " — ");
            try writeBool(out, alloc, b);
        },
        .str => |s| {
            try out.appendSlice(alloc, " — ");
            try writeStr(out, alloc, s);
        },
        .agg => |a| {
            try out.appendSlice(alloc, " — ");
            switch (a.kind) {
                .list => try out.appendSlice(alloc, "<list>"),
                .map => try out.appendSlice(alloc, "<map>"),
                .buffer => {
                    var tmp: [32]u8 = undefined;
                    const s = try std.fmt.bufPrint(&tmp, "<Buffer {d} bytes>", .{a.len});
                    try out.appendSlice(alloc, s);
                },
                .module => try out.appendSlice(alloc, "<module>"),
                .function => try out.appendSlice(alloc, "<fn>"),
                .other => try out.appendSlice(alloc, "<ptr>"),
            }
        },
    }
}

/// Array formatting (`writeArray` parity): empty → `[]`; an all-integer array
/// whose values are printable bytes (32..126 / `\n` / `\t`) prints as a raw
/// string; otherwise `[a, b, c]` with recursive element formatting.
pub fn writeArray(out: *std.ArrayList(u8), alloc: std.mem.Allocator, arr: anytype) !void {
    if (arr.len == 0) {
        try out.appendSlice(alloc, "[]");
        return;
    }
    const Child = std.meta.Elem(@TypeOf(arr));
    if (comptime isIntChild(Child)) {
        var printable = true;
        for (arr) |x| {
            const ch: i128 = x;
            if (ch < 32 or ch > 126) {
                if (ch != '\n' and ch != '\t') {
                    printable = false;
                    break;
                }
            }
        }
        if (printable) {
            for (arr) |x| {
                const ch: u8 = @intCast(x);
                try out.append(alloc, ch);
            }
            return;
        }
    }
    try out.append(alloc, '[');
    for (arr, 0..) |x, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try writeValue(out, alloc, x);
    }
    try out.append(alloc, ']');
}

fn isIntChild(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        else => false,
    };
}

/// Generic value formatting for emitted print sites. Supports optionals
/// (LLTS `null`), bools, all integer/float widths, strings, byte buffers,
/// arrays, and error values. Structs other than `Error` are a compile error —
/// the emitter formats those with layout-driven code in a later phase.
pub fn writeValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: anytype) !void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => {
            if (v) |inner| {
                try writeValue(out, alloc, inner);
            } else {
                try writeNull(out, alloc);
            }
        },
        .bool => try writeBool(out, alloc, v),
        .int => try writeInt(out, alloc, v),
        .float => {
            if (T == f32) {
                try writeFloat32(out, alloc, v);
            } else if (T == f64) {
                try writeFloat(out, alloc, v);
            } else {
                @compileError("print: unsupported float width " ++ @typeName(T));
            }
        },
        .array => {
            if (comptime std.meta.Elem(T) == u8) {
                try writeBytes(out, alloc, &v);
            } else {
                try writeArray(out, alloc, &v);
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (comptime p.child == u8) {
                    if (p.is_const) {
                        try writeStr(out, alloc, v);
                    } else {
                        try writeBytes(out, alloc, v);
                    }
                } else {
                    try writeArray(out, alloc, v);
                }
            },
            .one => {
                // Pointer-to-array (string literals, `&local_array`): const
                // pointers are strings (raw); mutable ones use array rules.
                if (comptime @typeInfo(p.child) == .array) {
                    if (p.is_const) {
                        try writeStr(out, alloc, v[0..]);
                    } else {
                        try writeValue(out, alloc, v.*);
                    }
                } else {
                    @compileError("print: pointer printing not supported in R1 (" ++ @typeName(T) ++ ")");
                }
            },
            else => @compileError("print: pointer printing not supported in R1 (" ++ @typeName(T) ++ ")"),
        },
        .@"struct" => {
            if (T == err_mod.Error) {
                try writeError(out, alloc, v);
            } else if (T == Addr) {
                var tmp: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&tmp, "0x{x}", .{v.value});
                try out.appendSlice(alloc, s);
            } else {
                @compileError("print: unsupported struct type " ++ @typeName(T));
            }
        },
        .@"union" => {
            if (T == err_mod.Payload) {
                switch (v) {
                    .none => try writeNull(out, alloc),
                    .int => |n| try writeInt(out, alloc, n),
                    .float => |n| try writeFloat(out, alloc, n),
                    .boolean => |b| try writeBool(out, alloc, b),
                    .str => |s| try writeStr(out, alloc, s),
                    .agg => |a| switch (a.kind) {
                        .list => try out.appendSlice(alloc, "<list>"),
                        .map => try out.appendSlice(alloc, "<map>"),
                        .buffer => {
                            var tmp: [32]u8 = undefined;
                            const s = try std.fmt.bufPrint(&tmp, "<Buffer {d} bytes>", .{a.len});
                            try out.appendSlice(alloc, s);
                        },
                        .module => try out.appendSlice(alloc, "<module>"),
                        .function => try out.appendSlice(alloc, "<fn>"),
                        .other => try out.appendSlice(alloc, "<ptr>"),
                    },
                }
            } else if (comptime @hasField(T, "ok") and @hasField(T, "err") and
                @FieldType(T, "err") == err_mod.Error)
            {
                switch (v) {
                    .ok => |inner| try writeValue(out, alloc, inner),
                    .err => |e| try writeError(out, alloc, e),
                }
            } else {
                @compileError("print: unsupported union type " ++ @typeName(T));
            }
        },
        else => @compileError("print: unsupported type " ++ @typeName(T)),
    }
}

/// `print(...)` — space-joined arguments, trailing newline, unbuffered
/// stdout write (VM printArgs parity).
pub fn print(ctx: *Context, args: anytype) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    inline for (args, 0..) |arg, i| {
        if (i > 0) try buf.append(ctx.allocator, ' ');
        try writeValue(&buf, ctx.allocator, arg);
    }
    try buf.append(ctx.allocator, '\n');
    io.writeStdout(buf.items);
}
