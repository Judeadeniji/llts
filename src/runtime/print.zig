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
const mem = @import("mem.zig");

/// Wrapper used by emitted `print(@addrOf(x))` to render raw hex pointers.
pub const Addr = struct { value: usize };

/// Wrapper used by emitted `print(struct)` to render LLTS packed bytes.
pub const Struct = struct { bytes: []const u8 };

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

/// Escaped string with double quotes for objects/arrays (Node.js/Bun parity).
pub fn writeEscapedStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '"');
}

pub fn writeIndent(out: *std.ArrayList(u8), alloc: std.mem.Allocator, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.appendSlice(alloc, "  ");
    }
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

/// `Error: <code>` (VM error-arm parity).
pub fn writeError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, e: err_mod.Error) !void {
    try out.appendSlice(alloc, "Error: ");
    try out.appendSlice(alloc, e.message);
}

/// Array formatting (`writeArray` parity): empty → `[]`; an all-integer array
/// whose values are printable bytes (32..126 / `\n` / `\t`) prints as a raw
/// string; otherwise `[a, b, c]` with recursive element formatting.
pub fn writeArray(out: *std.ArrayList(u8), alloc: std.mem.Allocator, arr: anytype) anyerror!void {
    try writeArrayIndent(out, alloc, arr, 0, false);
}

pub fn writeArrayIndent(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    arr: anytype,
    indent: usize,
    in_object: bool,
) anyerror!void {
    if (arr.len == 0) {
        try out.appendSlice(alloc, "[]");
        return;
    }
    const Child = std.meta.Elem(@TypeOf(arr));
    if (!in_object and comptime isIntChild(Child)) {
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

    const is_elem_struct = comptime blk: {
        var C = Child;
        if (@typeInfo(C) == .pointer and @typeInfo(C).pointer.size == .one) {
            C = @typeInfo(C).pointer.child;
        }
        break :blk @typeInfo(C) == .@"struct" and @hasDecl(C, "lls_field_names") and (!@hasDecl(C, "is_tuple") or !C.is_tuple);
    };

    if (is_elem_struct) {
        try out.appendSlice(alloc, "[\n");
        for (arr, 0..) |x, i| {
            if (i == 0) {
                try writeIndent(out, alloc, indent + 1);
            }
            try writeValueIndent(out, alloc, x, indent + 1, true);
            if (i + 1 < arr.len) {
                try out.appendSlice(alloc, ", ");
            } else {
                try out.append(alloc, '\n');
            }
        }
        try writeIndent(out, alloc, indent);
        try out.append(alloc, ']');
        return;
    }

    if (in_object) {
        try out.appendSlice(alloc, "[ ");
        for (arr, 0..) |x, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try writeValueIndent(out, alloc, x, indent, true);
        }
        try out.appendSlice(alloc, " ]");
    } else {
        try out.append(alloc, '[');
        for (arr, 0..) |x, i| {
            if (i > 0) try out.appendSlice(alloc, ", ");
            try writeValueIndent(out, alloc, x, indent, false);
        }
        try out.append(alloc, ']');
    }
}

fn isIntChild(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        else => false,
    };
}

pub fn writeStructIndent(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    v: anytype,
    indent: usize,
) anyerror!void {
    if (indent > 32) {
        try out.appendSlice(alloc, "[Circular]");
        return;
    }
    const T = @TypeOf(v);
    const struct_name: []const u8 = if (comptime @hasDecl(T, "lls_struct_name")) T.lls_struct_name else "";
    const field_count = std.meta.fields(T).len;

    if (field_count == 0) {
        if (struct_name.len > 0) {
            try out.appendSlice(alloc, struct_name);
            try out.appendSlice(alloc, " {}");
        } else {
            try out.appendSlice(alloc, "{}");
        }
        return;
    }

    if (struct_name.len > 0) {
        try out.appendSlice(alloc, struct_name);
        try out.appendSlice(alloc, " {\n");
    } else {
        try out.appendSlice(alloc, "{\n");
    }

    inline for (std.meta.fields(T), 0..) |field, idx| {
        try writeIndent(out, alloc, indent + 1);
        const fname: []const u8 = if (comptime @hasDecl(T, "lls_field_names"))
            T.lls_field_names[idx]
        else
            field.name;
        try out.appendSlice(alloc, fname);
        try out.appendSlice(alloc, ": ");
        try writeValueIndent(out, alloc, @field(v, field.name), indent + 1, true);
        try out.appendSlice(alloc, ",\n");
    }

    try writeIndent(out, alloc, indent);
    try out.append(alloc, '}');
}

/// Generic value formatting for emitted print sites. Supports optionals
/// (LLTS `null`), bools, all integer/float widths, strings, byte buffers,
/// arrays, structs formatted like Node.js/Bun objects, and error values.
pub fn writeValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: anytype) anyerror!void {
    try writeValueIndent(out, alloc, v, 0, false);
}

pub fn writeValueIndent(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    v: anytype,
    indent: usize,
    in_object: bool,
) anyerror!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => {
            if (v) |inner| {
                try writeValueIndent(out, alloc, inner, indent, in_object);
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
                if (in_object) {
                    try writeEscapedStr(out, alloc, &v);
                } else {
                    try writeBytes(out, alloc, &v);
                }
            } else {
                try writeArrayIndent(out, alloc, &v, indent, in_object);
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (comptime p.child == u8) {
                    if (in_object) {
                        try writeEscapedStr(out, alloc, v);
                    } else if (p.is_const) {
                        try writeStr(out, alloc, v);
                    } else {
                        try writeBytes(out, alloc, v);
                    }
                } else {
                    try writeArrayIndent(out, alloc, v, indent, in_object);
                }
            },
            .one => {
                if (comptime @typeInfo(p.child) == .array) {
                    if (p.is_const) {
                        if (in_object) {
                            try writeEscapedStr(out, alloc, v[0..]);
                        } else {
                            try writeStr(out, alloc, v[0..]);
                        }
                    } else {
                        try writeValueIndent(out, alloc, v.*, indent, in_object);
                    }
                } else if (comptime @typeInfo(p.child) == .@"struct") {
                    try writeValueIndent(out, alloc, v.*, indent, in_object);
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
            } else if (T == Struct) {
                try writeBytes(out, alloc, v.bytes);
            } else if (comptime @hasDecl(T, "is_tuple") and T.is_tuple) {
                try out.append(alloc, '[');
                inline for (std.meta.fields(T), 0..) |f, idx| {
                    if (idx > 0) try out.appendSlice(alloc, ", ");
                    try writeValueIndent(out, alloc, @field(v, f.name), indent, in_object);
                }
                try out.append(alloc, ']');
            } else if (comptime @hasDecl(T, "lls_field_names")) {
                try writeStructIndent(out, alloc, v, indent);
            } else if (comptime @hasDecl(T, "to_bytes")) {
                const b = v.to_bytes();
                try writeBytes(out, alloc, &b);
            } else {
                @compileError("print: unsupported struct type " ++ @typeName(T));
            }
        },
        .@"union" => {
            if (comptime @hasField(T, "ok") and @hasField(T, "err") and
                @FieldType(T, "err") == err_mod.Error)
            {
                switch (v) {
                    .ok => |inner| try writeValueIndent(out, alloc, inner, indent, in_object),
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

fn displayToFrame(ctx: *Context, value: anytype) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    try writeValue(&buf, ctx.allocator, value);
    return mem.concat(ctx, buf.items, "");
}

/// `@concat(allocator, a, b)` — stringify both operands (VM `+` parity) and
/// join into a fresh frame allocation.
pub fn concatDisplay(ctx: *Context, a: anytype, b: anytype) ![]const u8 {
    const left = try displayToFrame(ctx, a);
    const right = try displayToFrame(ctx, b);
    return mem.concat(ctx, left, right);
}
