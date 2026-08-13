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
    try stack.push(vm, vm.memory[@intCast(p + i)]);
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
    vm.memory[@intCast(p + i)] = val;
    try stack.push(vm, val);
}

fn asArrayPtr(vm: *VMState, v: Value) ?i32 {
    return switch (v) {
        .ptr => |x| x,
        // Heap loads are untyped i32s (TS parity): in-range ints are pointers.
        .int => |x| if (x >= state_mod.HEAP_START and x < vm.heap_ptr) @intCast(x) else null,
        else => null,
    };
}



pub fn getArray(vm: *VMState) HeapError!void {
    const idx = stack.pop(vm);
    const ptr = stack.pop(vm);
    const p = asArrayPtr(vm, ptr) orelse return fail(vm, "Indexing non-array");
    const i = switch (idx) {
        .int => |x| x,
        else => return fail(vm, "Index must be int"),
    };
    const len_val = vm.memory[@intCast(p - 1)];
    const len = len_val.int;
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    try stack.push(vm, vm.memory[@intCast(p + i)]);
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
    const len_val = vm.memory[@intCast(p - 1)];
    const len = len_val.int;
    if (i < 0 or i >= len) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Array index out of bounds: {d} (len {d}); use len(arr)", .{ i, len }) catch "Array index out of bounds";
        return fail(vm, msg);
    }
    vm.memory[@intCast(p + i)] = val;
    try stack.push(vm, val);
}



pub fn makeString(vm: *VMState) HeapError!void {
    const name_val = stack.pop(vm);
    try stack.push(vm, name_val); // Keep as .name, zero alloc!
}

pub fn makeError(vm: *VMState) HeapError!void {
    const msg = stack.pop(vm);
    // Immortal: `return error(…)` must survive the frame (escape policy allows error returns).
    const p = try vm.allocImmortal(2);
    vm.memory[@intCast(p)] = .{ .int = ERROR_TAG };
    vm.memory[@intCast(p + 1)] = msg;
    try stack.push(vm, .{ .ptr = p + 1 });
}

pub fn isError(vm: *VMState) HeapError!void {
    const val = stack.pop(vm);
    const p: ?i32 = switch (val) {
        .ptr => |x| x,
        .int => |x| if (x >= state_mod.HEAP_START and x < vm.heap_ptr) @intCast(x) else null,
        else => null,
    };
    const ok = if (p) |ptr|
        ptr >= state_mod.HEAP_START and vm.memory[@intCast(ptr - 1)] == .int and vm.memory[@intCast(ptr - 1)].int == ERROR_TAG
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
            const len: usize = @intCast(vm.memory[@intCast(p - 1)].int);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try list.append(vm.allocator, @intCast(vm.memory[@intCast(p + @as(i32, @intCast(i)))].int));
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
