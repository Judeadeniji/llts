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
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try appendStr(vm, &vm.string_bytes, a);
    try appendStr(vm, &vm.string_bytes, b);
    const total_len = vm.string_bytes.items.len - offset;
    try stack.push(vm, .{ .slice = .{ .offset = offset, .len = @intCast(total_len) } });
}

fn appendStr(vm: *VMState, list: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .name => |idx| try list.appendSlice(vm.allocator, vm.chunk.stringAt(idx)),
        .slice => |s| try list.appendSlice(vm.allocator, vm.string_bytes.items[s.offset .. s.offset + s.len]),
        .ptr => |p| {
            const len: usize = @intCast(vm.slot(p - 1).*.int);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try list.append(vm.allocator, @intCast(vm.slot(p + @as(i32, @intCast(i))).*.int));
            }
        },
        .bytes => |b| try list.appendSlice(vm.allocator, vm.bytes.items[b.offset..][0..b.len]),
        .int => |n| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            try list.appendSlice(vm.allocator, s);
        },
        else => {},
    }
}
