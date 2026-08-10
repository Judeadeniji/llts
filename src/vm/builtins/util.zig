const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const ERROR_TAG = state_mod.ERROR_TAG;

/// Read a length-prefixed heap string at `ptr` into an owned buffer.
pub fn readString(vm: *VMState, ptr: i32) ![]u8 {
    if (ptr < 1 or ptr >= vm.heap_ptr) return error.TypeError;
    const len: usize = @intCast(vm.memory[@intCast(ptr - 1)].int);
    const buf = try vm.allocator.alloc(u8, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = @intCast(vm.memory[@intCast(ptr + @as(i32, @intCast(i)))] .int);
    }
    return buf;
}

/// Allocate a length-prefixed string on the VM heap; returns data pointer.
/// Immortal: results are often returned from stdlib wrappers (`string.split`, etc.).
pub fn writeString(vm: *VMState, bytes: []const u8) !Value {
    const len: i32 = @intCast(bytes.len);
    const base = try vm.allocImmortal(len + 1);
    vm.memory[@intCast(base)] = .{ .int = len };
    for (bytes, 0..) |ch, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = .{ .int = ch };
    }
    return .{ .ptr = base + 1 };
}

/// Appends string bytes to the zero-alloc string arena and returns a string slice.
pub fn writeSlice(vm: *VMState, bytes: []const u8) !Value {
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.appendSlice(vm.allocator, bytes);
    return .{ .slice = .{ .offset = offset, .len = @intCast(bytes.len) } };
}

/// Allocate an error object `[ERROR_TAG, msgPtr]` and return ptr to msgPtr slot.
pub fn makeError(vm: *VMState, msg: []const u8) !Value {
    const msg_val = try writeSlice(vm, msg);
    const p = try vm.allocImmortal(2);
    vm.memory[@intCast(p)] = .{ .int = ERROR_TAG };
    vm.memory[@intCast(p + 1)] = msg_val;
    return .{ .ptr = p + 1 };
}

/// Write an array of i32 values (length-prefixed); returns data pointer.
/// Immortal: returned from natives like `__split` through LLTS wrappers.
/// Heap addresses are stored as `.ptr` so `print` / string ops see strings, not raw ints.
pub fn writeArray(vm: *VMState, items: []const Value) !Value {
    const len: i32 = @intCast(items.len);
    const base = try vm.allocImmortal(len + 1);
    vm.memory[@intCast(base)] = .{ .int = len };
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
        .slice => |s| try vm.allocator.dupe(u8, vm.string_bytes.items[s.offset .. s.offset + s.len]),
        else => error.TypeError,
    };
}

/// Zero-alloc deep string equality check across all string representations.
pub fn stringEquals(vm: *VMState, a: Value, b: Value) bool {
    const is_str_a = a == .name or a == .slice or a == .ptr;
    const is_str_b = b == .name or b == .slice or b == .ptr;
    if (!is_str_a or !is_str_b) return false;
    
    // Quick fast paths for identical tags
    if (a == .name and b == .name) return a.name == b.name;
    if (a == .slice and b == .slice) {
        if (a.slice.len != b.slice.len) return false;
        if (a.slice.offset == b.slice.offset) return true;
    }
    
    // Get lengths
    const len_a: usize = switch (a) {
        .slice => |s| s.len,
        .name => |idx| vm.chunk.stringAt(idx).len,
        .ptr => |p| @intCast(vm.memory[@intCast(p - 1)].int),
        else => unreachable,
    };
    
    const len_b: usize = switch (b) {
        .slice => |s| s.len,
        .name => |idx| vm.chunk.stringAt(idx).len,
        .ptr => |p| @intCast(vm.memory[@intCast(p - 1)].int),
        else => unreachable,
    };
    
    if (len_a != len_b) return false;
    
    // Fallback: byte-by-byte comparison
    var i: usize = 0;
    while (i < len_a) : (i += 1) {
        const char_a: u8 = switch (a) {
            .slice => |s| vm.string_bytes.items[s.offset + i],
            .name => |idx| vm.chunk.stringAt(idx)[i],
            .ptr => |p| @intCast(vm.memory[@intCast(p + @as(i32, @intCast(i)))].int),
            else => unreachable,
        };
        const char_b: u8 = switch (b) {
            .slice => |s| vm.string_bytes.items[s.offset + i],
            .name => |idx| vm.chunk.stringAt(idx)[i],
            .ptr => |p| @intCast(vm.memory[@intCast(p + @as(i32, @intCast(i)))].int),
            else => unreachable,
        };
        if (char_a != char_b) return false;
    }
    
    return true;
}
