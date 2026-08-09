const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const ERROR_TAG = state_mod.ERROR_TAG;

/// Read a length-prefixed heap string at `ptr` into an owned buffer.
pub fn readString(vm: *VMState, ptr: i32) ![]u8 {
    if (ptr < 1 or ptr >= vm.heap_ptr) return error.TypeError;
    const len: usize = @intCast(vm.memory[@intCast(ptr - 1)]);
    const buf = try vm.allocator.alloc(u8, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = @intCast(vm.memory[@intCast(ptr + @as(i32, @intCast(i)))]);
    }
    return buf;
}

/// Allocate a length-prefixed string on the VM heap; returns data pointer.
pub fn writeString(vm: *VMState, bytes: []const u8) !Value {
    const len: i32 = @intCast(bytes.len);
    const base = try vm.allocSlots(len + 1);
    vm.memory[@intCast(base)] = len;
    for (bytes, 0..) |ch, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = ch;
    }
    return .{ .ptr = base + 1 };
}

/// Allocate an error object `[ERROR_TAG, msgPtr]` and return ptr to msgPtr slot.
pub fn makeError(vm: *VMState, msg: []const u8) !Value {
    const msg_val = try writeString(vm, msg);
    const msg_ptr = msg_val.ptr;
    const p = try vm.allocSlots(2);
    vm.memory[@intCast(p)] = ERROR_TAG;
    vm.memory[@intCast(p + 1)] = msg_ptr;
    return .{ .ptr = p + 1 };
}

/// Write an array of i32 values (length-prefixed); returns data pointer.
pub fn writeArray(vm: *VMState, items: []const i32) !Value {
    const len: i32 = @intCast(items.len);
    const base = try vm.allocSlots(len + 1);
    vm.memory[@intCast(base)] = len;
    for (items, 0..) |item, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = item;
    }
    return .{ .ptr = base + 1 };
}

pub fn asInt(v: Value) !i32 {
    return switch (v) {
        .int => |n| n,
        .ptr => |p| p,
        .bool => |b| @intFromBool(b),
        .float => |n| @intFromFloat(n),
        .null => 0,
        else => error.TypeError,
    };
}

pub fn asPtr(v: Value) !i32 {
    return switch (v) {
        .ptr => |p| p,
        .int => |n| if (n >= state_mod.HEAP_START) n else error.TypeError,
        else => error.TypeError,
    };
}

/// Read string from a Value that is either a heap ptr or interned name.
pub fn valueToOwnedString(vm: *VMState, v: Value) ![]u8 {
    return switch (v) {
        .ptr => |p| try readString(vm, p),
        .name => |idx| try vm.allocator.dupe(u8, vm.chunk.stringAt(idx)),
        else => error.TypeError,
    };
}
