const std = @import("std");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const runtime = @import("../../errors/runtime.zig");

const VMState = state_mod.VMState;
const Value = state_mod.Value;
const ERROR_TAG = state_mod.ERROR_TAG;

pub const HeapError = error{ RuntimeError, OutOfMemory, IndexOutOfBounds, TypeError, NoSpaceLeft };

fn fail(vm: *VMState, msg: []const u8) HeapError {
    return runtime.runtimeFail(vm, msg);
}

pub fn getIndex(vm: *VMState) HeapError!void {
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const i = switch (idx) {
        .i64 => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    switch (ptr) {
        .bytes => |b| {
            if (i < 0 or i >= b.len) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, b.len }) catch "Array index out of bounds";
                return fail(vm, msg);
            }
            try stack.push(vm, .{ .u8 = vm.bytes.items[b.offset + @as(u32, @intCast(i))] });
            return;
        },
        .array => |a| {
            if (i < 0 or i >= a.count) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, a.count }) catch "Array index out of bounds";
                return fail(vm, msg);
            }
            try stack.push(vm, vm.arrayElemConst(a, @intCast(i)));
            return;
        },
        .slice => |s| {
            if (i < 0 or i >= s.len) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Slice index out of bounds: {d} (len {d}); use len(slice)", .{ i, s.len }) catch "Slice index out of bounds";
                return fail(vm, msg);
            }
            try stack.push(vm, vm.slot(@as(i32, @intCast(s.offset)) + @as(i32, @intCast(i))).*);
            return;
        },
        .name => |name_idx| {
            const str = vm.chunk.stringAt(name_idx);
            if (i < 0 or i >= str.len) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "String index out of bounds: {d} (len {d}); use len(str)", .{ i, str.len }) catch "String index out of bounds";
                return fail(vm, msg);
            }
            try stack.push(vm, .{ .u8 = str[@intCast(i)] });
            return;
        },
        .ptr => |p| {
            try stack.push(vm, vm.slot(p + @as(i32, @intCast(i))).*);
            return;
        },
        .null => return fail(vm, "Cannot access field of null"),
        else => return fail(vm, "Indexing non-pointer"),
    }
}

pub fn setIndex(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const i = switch (idx) {
        .i64 => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    switch (ptr) {
        .bytes => |b| {
            if (i < 0 or i >= b.len) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, b.len }) catch "Array index out of bounds";
                return fail(vm, msg);
            }
            const n = switch (val) {
                .u8 => |x| @as(i64, x),
                .i64 => |x| x,
                else => return fail(vm, "Byte store requires u8 or int"),
            };
            if (n < 0 or n > 255) return fail(vm, "Byte value out of range 0..255");
            const bval: u8 = @intCast(n);
            vm.bytes.items[b.offset + @as(u32, @intCast(i))] = bval;
            try stack.push(vm, .{ .u8 = bval });
            return;
        },
        .array => |a| {
            if (i < 0 or i >= a.count) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, a.count }) catch "Array index out of bounds";
                return fail(vm, msg);
            }
            vm.arrayElemPtr(a, @intCast(i)).* = val;
            try stack.push(vm, val);
            return;
        },
        .ptr => |p| {
            vm.slot(p + @as(i32, @intCast(i))).* = val;
            try stack.push(vm, val);
            return;
        },
        .null => return fail(vm, "Cannot access field of null"),
        else => return fail(vm, "Indexing non-pointer"),
    }
}

fn asArrayPtr(vm: *VMState, v: Value) ?i32 {
    return switch (v) {
        .ptr => |x| x,
        // Heap loads are untyped i32s (TS parity): in-range ints are pointers.
        .i64 => |x| if (vm.isValidHeapPtr(x)) @intCast(x) else null,
        else => null,
    };
}



pub fn getArray(vm: *VMState) HeapError!void {
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const i = switch (idx) {
        .i64 => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    if (ptr == .bytes) {
        const b = ptr.bytes;
        if (i < 0 or i >= b.len) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, b.len }) catch "Array index out of bounds";
            return fail(vm, msg);
        }
        try stack.push(vm, .{ .u8 = vm.bytes.items[b.offset + @as(u32, @intCast(i))] });
        return;
    }
    if (ptr == .array) {
        const a = ptr.array;
        if (i < 0 or i >= a.count) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, a.count }) catch "Array index out of bounds";
            return fail(vm, msg);
        }
        try stack.push(vm, vm.arrayElemConst(a, @intCast(i)));
        return;
    }
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const len_val = vm.slot(p - 1).*;
    const len = len_val.i64;
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    try stack.push(vm, vm.slot(p + @as(i32, @intCast(i))).*);
}

/// Stack: [obj, lo, hi|null] → view into packed bytes/string (exclusive hi).
/// Null `hi` means "to end" (`obj[lo..]`).
pub fn sliceView(vm: *VMState) HeapError!void {
    const hi_v = stack.pop(vm);
    const lo_v = stack.pop(vm);
    const obj = stack.pop(vm);
    const widths = @import("../../compiler/widths.zig");
    const lo = widths.valueAsI64(lo_v) orelse return fail(vm, "Slice start must be int");

    if (obj == .name) {
        const data = vm.chunk.stringAt(obj.name);
        const hi: i64 = switch (hi_v) {
            .null => @intCast(data.len),
            else => widths.valueAsI64(hi_v) orelse return fail(vm, "Slice end must be int"),
        };
        if (lo < 0 or hi < lo or hi > data.len) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Slice out of bounds: [{d}..{d}] (len {d})", .{ lo, hi, data.len }) catch "Slice out of bounds";
            return fail(vm, msg);
        }
        const sub = data[@intCast(lo)..@intCast(hi)];
        const off = try vm.appendImmortal(sub);
        try stack.push(vm, .{ .slice = .{ .offset = off, .len = @intCast(sub.len) } });
        return;
    }

    const offset: u32, const len: u32, const as_bytes: bool = switch (obj) {
        .bytes => |b| .{ b.offset, b.len, true },
        .slice => |s| .{ s.offset, s.len, false },
        else => return fail(vm, "Slice requires []byte or string"),
    };
    const hi: i64 = switch (hi_v) {
        .null => @intCast(len),
        else => widths.valueAsI64(hi_v) orelse return fail(vm, "Slice end must be int"),
    };
    if (lo < 0 or hi < lo or hi > len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Slice out of bounds: [{d}..{d}] (len {d})", .{ lo, hi, len }) catch "Slice out of bounds";
        return fail(vm, msg);
    }
    const start: u32 = @intCast(lo);
    const n: u32 = @intCast(hi - lo);
    if (as_bytes) {
        try stack.push(vm, .{ .bytes = .{ .offset = offset + start, .len = n } });
    } else {
        try stack.push(vm, .{ .slice = .{ .offset = offset + start, .len = n } });
    }
}

pub fn setArray(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const i = switch (idx) {
        .i64 => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    if (ptr == .bytes) {
        const b = ptr.bytes;
        if (i < 0 or i >= b.len) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, b.len }) catch "Array index out of bounds";
            return fail(vm, msg);
        }
        const n = switch (val) {
            .u8 => |x| @as(i64, x),
            .i64 => |x| x,
            else => return fail(vm, "Byte store requires u8 or int"),
        };
        if (n < 0 or n > 255) return fail(vm, "Byte value out of range 0..255");
        const bval: u8 = @intCast(n);
        vm.bytes.items[b.offset + @as(u32, @intCast(i))] = bval;
        try stack.push(vm, .{ .u8 = bval });
        return;
    }
    if (ptr == .array) {
        const a = ptr.array;
        if (i < 0 or i >= a.count) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, a.count }) catch "Array index out of bounds";
            return fail(vm, msg);
        }
        vm.arrayElemPtr(a, @intCast(i)).* = val;
        try stack.push(vm, val);
        return;
    }
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const len_val = vm.slot(p - 1).*;
    const len = len_val.i64;
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    vm.slot(p + @as(i32, @intCast(i))).* = val;
    try stack.push(vm, val);
}

fn baseBytesOffset(vm: *VMState, base: Value) HeapError!u32 {
    return switch (base) {
        .bytes => |b| b.offset,
        else => return fail(vm, "Packed field access requires a byte object"),
    };
}

fn writeU32(vm: *VMState, at: u32, n: u32) void {
    std.mem.writeInt(u32, vm.bytes.items[at..][0..4], n, .little);
}

fn readU32(vm: *const VMState, at: u32) u32 {
    return std.mem.readInt(u32, vm.bytes.items[at..][0..4], .little);
}

fn writeI64(vm: *VMState, at: u32, n: i64) void {
    std.mem.writeInt(i64, vm.bytes.items[at..][0..8], n, .little);
}

fn readI64(vm: *const VMState, at: u32) i64 {
    return std.mem.readInt(i64, vm.bytes.items[at..][0..8], .little);
}

fn writeF64(vm: *VMState, at: u32, n: f64) void {
    const bits: u64 = @bitCast(n);
    std.mem.writeInt(u64, vm.bytes.items[at..][0..8], bits, .little);
}

fn readF64(vm: *const VMState, at: u32) f64 {
    const bits = std.mem.readInt(u64, vm.bytes.items[at..][0..8], .little);
    return @bitCast(bits);
}

fn writeF32(vm: *VMState, at: u32, n: f32) void {
    const bits: u32 = @bitCast(n);
    std.mem.writeInt(u32, vm.bytes.items[at..][0..4], bits, .little);
}

fn readF32(vm: *const VMState, at: u32) f32 {
    const bits = std.mem.readInt(u32, vm.bytes.items[at..][0..4], .little);
    return @bitCast(bits);
}

const HANDLE_NULL_OFFSET: u32 = 0xFFFF_FFFF;
/// Handle `len` sentinel: `offset` is a Value-slot index holding `.function` / `.native`.
const HANDLE_BOXED_VALUE: u32 = 0xFFFF_FFFE;

fn writeI8(vm: *VMState, at: u32, n: i8) void {
    vm.bytes.items[at] = @bitCast(n);
}
fn readI8(vm: *const VMState, at: u32) i8 {
    return @bitCast(vm.bytes.items[at]);
}
fn writeI16(vm: *VMState, at: u32, n: i16) void {
    std.mem.writeInt(i16, vm.bytes.items[at..][0..2], n, .little);
}
fn readI16(vm: *const VMState, at: u32) i16 {
    return std.mem.readInt(i16, vm.bytes.items[at..][0..2], .little);
}
fn writeI32(vm: *VMState, at: u32, n: i32) void {
    std.mem.writeInt(i32, vm.bytes.items[at..][0..4], n, .little);
}
fn readI32(vm: *const VMState, at: u32) i32 {
    return std.mem.readInt(i32, vm.bytes.items[at..][0..4], .little);
}
fn writeU16(vm: *VMState, at: u32, n: u16) void {
    std.mem.writeInt(u16, vm.bytes.items[at..][0..2], n, .little);
}
fn readU16(vm: *const VMState, at: u32) u16 {
    return std.mem.readInt(u16, vm.bytes.items[at..][0..2], .little);
}
fn writeU64(vm: *VMState, at: u32, n: u64) void {
    std.mem.writeInt(u64, vm.bytes.items[at..][0..8], n, .little);
}
fn readU64(vm: *const VMState, at: u32) u64 {
    return std.mem.readInt(u64, vm.bytes.items[at..][0..8], .little);
}

/// Stack: [base] → [field value].
pub fn loadField(vm: *VMState, byte_offset: u16, kind: u8) HeapError!void {
    const base = stack.pop(vm);
    const base_off = try baseBytesOffset(vm, base);
    const at = base_off + byte_offset;
    const val: Value = switch (kind) {
        0 => .{ .i64 = readI64(vm, at) },
        1 => .{ .f64 = readF64(vm, at) },
        2 => .{ .u1 = if (vm.bytes.items[at] != 0) 1 else 0 },
        3 => blk: {
            const off = readU32(vm, at);
            const len = readU32(vm, at + 4);
            if (off == HANDLE_NULL_OFFSET) break :blk .null;
            if (len == HANDLE_BOXED_VALUE) {
                break :blk vm.slot(@intCast(off)).*;
            }
            break :blk .{ .bytes = .{ .offset = off, .len = len } };
        },
        4 => .{ .ptr = @intCast(readI64(vm, at)) },
        5 => .{ .u8 = vm.bytes.items[at] },
        6 => .{ .f32 = readF32(vm, at) },
        7 => .{ .i8 = readI8(vm, at) },
        8 => .{ .i16 = readI16(vm, at) },
        9 => .{ .i32 = readI32(vm, at) },
        10 => .{ .u16 = readU16(vm, at) },
        11 => .{ .u32 = readU32(vm, at) },
        12 => .{ .u64 = readU64(vm, at) },
        else => return fail(vm, "Unknown field kind"),
    };
    try stack.push(vm, val);
}

/// Stack: [base, value] → [value].
pub fn storeField(vm: *VMState, byte_offset: u16, kind: u8) HeapError!void {
    const val = stack.pop(vm);
    const base = stack.pop(vm);
    const base_off = try baseBytesOffset(vm, base);
    const at = base_off + byte_offset;
    const widths = @import("../../compiler/widths.zig");
    switch (kind) {
        0, 5, 7, 8, 9, 10, 11, 12 => {
            const w = @import("../../compiler/layout.zig").widthFromFieldKind(@enumFromInt(kind)).?;
            const casted = widths.castValue(val, w) catch return fail(vm, "Field store width mismatch / out of range");
            switch (casted) {
                .i8 => |x| writeI8(vm, at, x),
                .i16 => |x| writeI16(vm, at, x),
                .i32 => |x| writeI32(vm, at, x),
                .i64 => |x| writeI64(vm, at, x),
                .u8 => |x| vm.bytes.items[at] = x,
                .u16 => |x| writeU16(vm, at, x),
                .u32 => |x| writeU32(vm, at, x),
                .u64 => |x| writeU64(vm, at, x),
                else => return fail(vm, "Field store expects integer"),
            }
        },
        1 => {
            const casted = widths.castValue(val, .f64) catch return fail(vm, "Field store expects f64");
            writeF64(vm, at, casted.f64);
        },
        6 => {
            const casted = widths.castValue(val, .f32) catch return fail(vm, "Field store expects f32");
            writeF32(vm, at, casted.f32);
        },
        2 => {
            const b = switch (val) {
                .u1 => |x| x != 0,
                .i64 => |x| x != 0,
                .null => false,
                else => return fail(vm, "Field store expects u1"),
            };
            vm.bytes.items[at] = if (b) 1 else 0;
        },
        3 => {
            var off: u32 = HANDLE_NULL_OFFSET;
            var len: u32 = 0;
            switch (val) {
                .null => {},
                .bytes => |b| {
                    off = b.offset;
                    len = b.len;
                },
                .slice => |s| {
                    off = s.offset;
                    len = s.len;
                },
                .name => |idx| {
                    const data = vm.chunk.stringAt(idx);
                    off = try vm.appendImmortal(data);
                    len = @intCast(data.len);
                },
                .function, .native => {
                    const slot = try vm.allocImmortal(1);
                    vm.slot(slot).* = val;
                    off = @intCast(slot);
                    len = HANDLE_BOXED_VALUE;
                },
                else => return fail(vm, "Field store expects object handle"),
            }
            writeU32(vm, at, off);
            writeU32(vm, at + 4, len);
        },
        4 => {
            const p: i64 = switch (val) {
                .ptr => |x| x,
                .null => 0,
                .i64 => |x| x,
                else => return fail(vm, "Field store expects ptr"),
            };
            writeI64(vm, at, p);
        },
        else => return fail(vm, "Unknown field kind"),
    }
    try stack.push(vm, val);
}

pub fn makeString(vm: *VMState) HeapError!void {
    const name_val = stack.pop(vm);
    try stack.push(vm, name_val); // Keep as .name, zero alloc!
}

pub fn makeError(vm: *VMState) HeapError!void {
    const msg = stack.pop(vm);
    const p = try vm.allocImmortal(3);
    vm.slot(p).* = .{ .i64 = ERROR_TAG };
    vm.slot(p + 1).* = msg;
    vm.slot(p + 2).* = .null;
    try stack.push(vm, .{ .ptr = p + 1 });
}

pub fn makeErrorPayload(vm: *VMState) HeapError!void {
    const payload = stack.pop(vm);
    const msg = stack.pop(vm);
    const p = try vm.allocImmortal(3);
    vm.slot(p).* = .{ .i64 = ERROR_TAG };
    vm.slot(p + 1).* = msg;
    vm.slot(p + 2).* = payload;
    try stack.push(vm, .{ .ptr = p + 1 });
}

pub fn isError(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const p: ?i32 = switch (val) {
        .ptr => |x| x,
        .i64 => |x| if (vm.isValidHeapPtr(x)) @intCast(x) else null,
        else => null,
    };
    const ok = if (p) |ptr|
        ptr >= state_mod.HEAP_START and vm.isValidHeapPtr(ptr - 1) and vm.slot(ptr - 1).* == .i64 and vm.slot(ptr - 1).*.i64 == ERROR_TAG
    else
        false;
    try stack.push(vm, Value.fromBool(ok ));
}

pub fn stringAdd(vm: *VMState) HeapError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const offset = vm.bytes_ptr;
    try appendStr(vm, a);
    try appendStr(vm, b);
    const total_len = vm.bytes_ptr - offset;
    try stack.push(vm, .{ .slice = .{ .offset = offset, .len = total_len } });
}

fn appendStr(vm: *VMState, v: Value) !void {
    switch (v) {
        .name => |idx| _ = try vm.appendImmortal(vm.chunk.stringAt(idx)),
        .slice => |s| {
            if (s.len == 0) return;
            try vm.ensurePackedCapacity(s.len);
            const src = vm.bytes.items[s.offset .. s.offset + s.len];
            vm.bytes.appendSliceAssumeCapacity(src);
            vm.noteImmortalGrowth();
        },
        .ptr => |p| {
            const len: usize = @intCast(vm.slot(p - 1).*.i64);
            try vm.ensurePackedCapacity(len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                vm.bytes.appendAssumeCapacity(@intCast(vm.slot(p + @as(i32, @intCast(i))).*.i64));
            }
            vm.noteImmortalGrowth();
        },
        .bytes => |b| {
            try vm.ensurePackedCapacity(b.len);
            const src = vm.bytes.items[b.offset..][0..b.len];
            vm.bytes.appendSliceAssumeCapacity(src);
            vm.noteImmortalGrowth();
        },
        .i64 => |n| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            _ = try vm.appendImmortal(s);
        },
        .u8 => |n| {
            var buf: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            _ = try vm.appendImmortal(s);
        },
        else => {},
    }
}
