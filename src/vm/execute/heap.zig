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
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    switch (ptr) {
        .bytes => |b| {
            if (i < 0 or i >= b.len) {
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, b.len }) catch "Array index out of bounds";
                return fail(vm, msg);
            }
            try stack.push(vm, .{ .int = vm.bytes.items[b.offset + @as(u32, @intCast(i))] });
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
        .int => |x| x,
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
                .int => |x| x,
                else => return fail(vm, "Byte store requires int"),
            };
            if (n < 0 or n > 255) return fail(vm, "Byte value out of range 0..255");
            vm.bytes.items[b.offset + @as(u32, @intCast(i))] = @intCast(n);
            try stack.push(vm, .{ .int = n });
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
        .int => |x| if (vm.isValidHeapPtr(x)) @intCast(x) else null,
        else => null,
    };
}



pub fn getArray(vm: *VMState) HeapError!void {
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const i = switch (idx) {
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    if (ptr == .bytes) {
        const b = ptr.bytes;
        if (i < 0 or i >= b.len) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, b.len }) catch "Array index out of bounds";
            return fail(vm, msg);
        }
        try stack.push(vm, .{ .int = vm.bytes.items[b.offset + @as(u32, @intCast(i))] });
        return;
    }
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const len_val = vm.slot(p - 1).*;
    const len = len_val.int;
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    try stack.push(vm, vm.slot(p + @as(i32, @intCast(i))).*);
}

pub fn setArray(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const i = switch (idx) {
        .int => |x| x,
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
            .int => |x| x,
            else => return fail(vm, "Byte store requires int"),
        };
        if (n < 0 or n > 255) return fail(vm, "Byte value out of range 0..255");
        vm.bytes.items[b.offset + @as(u32, @intCast(i))] = @intCast(n);
        try stack.push(vm, .{ .int = n });
        return;
    }
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const len_val = vm.slot(p - 1).*;
    const len = len_val.int;
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

const HANDLE_NULL_OFFSET: u32 = 0xFFFF_FFFF;

/// Stack: [base] → [field value].
pub fn loadField(vm: *VMState, byte_offset: u16, kind: u8) HeapError!void {
    const base = stack.pop(vm);
    const base_off = try baseBytesOffset(vm, base);
    const at = base_off + byte_offset;
    const val: Value = switch (kind) {
        0 => .{ .int = readI64(vm, at) },
        1 => .{ .float = readF64(vm, at) },
        2 => .{ .bool = vm.bytes.items[at] != 0 },
        3 => blk: {
            const off = readU32(vm, at);
            const len = readU32(vm, at + 4);
            if (off == HANDLE_NULL_OFFSET) break :blk .null;
            // Nested structs and string/`[]byte` handles share this encoding.
            break :blk .{ .bytes = .{ .offset = off, .len = len } };
        },
        4 => .{ .ptr = @intCast(readI64(vm, at)) },
        5 => .{ .int = vm.bytes.items[at] },
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
    switch (kind) {
        0 => {
            const n = switch (val) {
                .int => |x| x,
                .bool => |b| @intFromBool(b),
                .null => @as(i64, 0),
                else => return fail(vm, "Field store expects int"),
            };
            writeI64(vm, at, n);
        },
        1 => {
            const n = switch (val) {
                .float => |x| x,
                .int => |x| @as(f64, @floatFromInt(x)),
                else => return fail(vm, "Field store expects float"),
            };
            writeF64(vm, at, n);
        },
        2 => {
            const b = switch (val) {
                .bool => |x| x,
                .int => |x| x != 0,
                .null => false,
                else => return fail(vm, "Field store expects bool"),
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
                else => return fail(vm, "Field store expects object handle"),
            }
            writeU32(vm, at, off);
            writeU32(vm, at + 4, len);
        },
        4 => {
            const p: i64 = switch (val) {
                .ptr => |x| x,
                .null => 0,
                .int => |x| x,
                else => return fail(vm, "Field store expects ptr"),
            };
            writeI64(vm, at, p);
        },
        5 => {
            const n = switch (val) {
                .int => |x| x,
                else => return fail(vm, "Field store expects byte"),
            };
            if (n < 0 or n > 255) return fail(vm, "Byte value out of range 0..255");
            vm.bytes.items[at] = @intCast(n);
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
    vm.slot(p).* = .{ .int = ERROR_TAG };
    vm.slot(p + 1).* = msg;
    vm.slot(p + 2).* = .null;
    try stack.push(vm, .{ .ptr = p + 1 });
}

pub fn makeErrorPayload(vm: *VMState) HeapError!void {
    const payload = stack.pop(vm);
    const msg = stack.pop(vm);
    const p = try vm.allocImmortal(3);
    vm.slot(p).* = .{ .int = ERROR_TAG };
    vm.slot(p + 1).* = msg;
    vm.slot(p + 2).* = payload;
    try stack.push(vm, .{ .ptr = p + 1 });
}

pub fn isError(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const p: ?i32 = switch (val) {
        .ptr => |x| x,
        .int => |x| if (vm.isValidHeapPtr(x)) @intCast(x) else null,
        else => null,
    };
    const ok = if (p) |ptr|
        ptr >= state_mod.HEAP_START and vm.isValidHeapPtr(ptr - 1) and vm.slot(ptr - 1).* == .int and vm.slot(ptr - 1).*.int == ERROR_TAG
    else
        false;
    try stack.push(vm, .{ .bool = ok });
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
            const len: usize = @intCast(vm.slot(p - 1).*.int);
            try vm.ensurePackedCapacity(len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                vm.bytes.appendAssumeCapacity(@intCast(vm.slot(p + @as(i32, @intCast(i))).*.int));
            }
            vm.noteImmortalGrowth();
        },
        .bytes => |b| {
            try vm.ensurePackedCapacity(b.len);
            const src = vm.bytes.items[b.offset..][0..b.len];
            vm.bytes.appendSliceAssumeCapacity(src);
            vm.noteImmortalGrowth();
        },
        .int => |n| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            _ = try vm.appendImmortal(s);
        },
        else => {},
    }
}
