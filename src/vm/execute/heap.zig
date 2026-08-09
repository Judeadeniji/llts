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
    const p = switch (ptr) {
        .ptr => |x| x,
        else => return fail(vm, "Indexing non-pointer"),
    };
    const i = switch (idx) {
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    try stack.push(vm, .{ .int = vm.memory[@intCast(p + i)] });
}

pub fn setIndex(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const p = switch (ptr) {
        .ptr => |x| x,
        else => return fail(vm, "Indexing non-pointer"),
    };
    const i = switch (idx) {
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    vm.memory[@intCast(p + i)] = valueToI32(val);
    try stack.push(vm, val);
}

fn asArrayPtr(vm: *VMState, v: Value) ?i32 {
    return switch (v) {
        .ptr => |x| x,
        // Heap loads are untyped i32s (TS parity): in-range ints are pointers.
        .int => |x| if (x >= state_mod.HEAP_START and x < vm.heap_ptr) x else null,
        else => null,
    };
}

fn heapValue(vm: *VMState, slot: i32) Value {
    const n = vm.memory[@intCast(slot)];
    if (n >= state_mod.HEAP_START and n < vm.heap_ptr) return .{ .ptr = n };
    return .{ .int = n };
}

pub fn getArray(vm: *VMState) HeapError!void {
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const i = switch (idx) {
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    const len = vm.memory[@intCast(p - 1)];
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    try stack.push(vm, heapValue(vm, p + i));
}

pub fn setArray(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const i = switch (idx) {
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    const len = vm.memory[@intCast(p - 1)];
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    vm.memory[@intCast(p + i)] = valueToI32(val);
    try stack.push(vm, val);
}

fn valueToI32(val: Value) i32 {
    return switch (val) {
        .int => |x| x,
        .ptr => |x| x,
        .bool => |b| @intFromBool(b),
        .float => |f| @intFromFloat(f),
        .null => 0,
        else => 0,
    };
}

pub fn makeString(vm: *VMState) HeapError!void {
    const name_val = stack.pop(vm);
    const s = switch (name_val) {
        .name => |idx| vm.chunk.stringAt(idx),
        else => return fail(vm, "Bad string constant"),
    };
    const len: i32 = @intCast(s.len);
    const base = try vm.allocSlots(len + 1);
    vm.memory[@intCast(base)] = len;
    for (s, 0..) |ch, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = ch;
    }
    try stack.push(vm, .{ .ptr = base + 1 });
}

pub fn makeError(vm: *VMState) HeapError!void {
    const msg = stack.pop(vm);
    const msg_ptr: i32 = switch (msg) {
        .ptr => |p| p,
        .int => |n| n,
        else => 0,
    };
    const p = try vm.allocSlots(2);
    vm.memory[@intCast(p)] = ERROR_TAG;
    vm.memory[@intCast(p + 1)] = msg_ptr;
    try stack.push(vm, .{ .ptr = p + 1 });
}

pub fn isError(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const p: ?i32 = switch (val) {
        .ptr => |x| x,
        .int => |x| if (x >= state_mod.HEAP_START and x < vm.heap_ptr) x else null,
        else => null,
    };
    const ok = if (p) |ptr|
        ptr >= state_mod.HEAP_START and vm.memory[@intCast(ptr - 1)] == ERROR_TAG
    else
        false;
    try stack.push(vm, .{ .bool = ok });
}

pub fn stringAdd(vm: *VMState) HeapError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(vm.allocator);
    try appendStr(vm, &list, a);
    try appendStr(vm, &list, b);
    const len: i32 = @intCast(list.items.len);
    const base = try vm.allocSlots(len + 1);
    vm.memory[@intCast(base)] = len;
    for (list.items, 0..) |ch, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = ch;
    }
    try stack.push(vm, .{ .ptr = base + 1 });
}

fn appendStr(vm: *VMState, list: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .name => |idx| try list.appendSlice(vm.allocator, vm.chunk.stringAt(idx)),
        .ptr => |p| {
            const len: usize = @intCast(vm.memory[@intCast(p - 1)]);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try list.append(vm.allocator, @intCast(vm.memory[@intCast(p + @as(i32, @intCast(i)))]));
            }
        },
        .int => |n| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            try list.appendSlice(vm.allocator, s);
        },
        else => {},
    }
}
