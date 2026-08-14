const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const ERROR_TAG = state_mod.ERROR_TAG;

/// Read a length-prefixed heap string at `ptr` into an owned buffer.
pub fn readString(vm: *VMState, ptr: i32) ![]u8 {
    if (ptr < 1 or !vm.isValidHeapPtr(ptr)) return error.TypeError;
    const len: usize = @intCast(vm.memory[@intCast(ptr - 1)].int);
    const buf = try vm.allocator.alloc(u8, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const val = vm.memory[@intCast(ptr + @as(i32, @intCast(i)))];
        switch (val) {
            .int => |ch| buf[i] = @intCast(ch),
            else => {
                vm.allocator.free(buf);
                return error.TypeError;
            }
        }
    }
    return buf;
}

/// Allocate a length-prefixed string on the VM heap; returns data pointer.
/// Immortal: results are often returned from stdlib wrappers (`string.split`, etc.).
pub fn writeString(vm: *VMState, bytes: []const u8) !Value {
    const len: i64 = @intCast(bytes.len);
    const base = try vm.allocImmortal(@intCast(len + 1));
    vm.memory[@intCast(base)] = .{ .int = len };
    for (bytes, 0..) |ch, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = .{ .int = ch };
    }
    return .{ .ptr = base + 1 };
}

/// Appends string bytes to the zero-alloc string arena and returns a string slice.
/// If `bytes` already lives in the arena, returns a view (no copy).
pub fn writeSlice(vm: *VMState, bytes: []const u8) !Value {
    if (bytes.len == 0) return .{ .slice = .{ .offset = 0, .len = 0 } };
    const items = vm.string_bytes.items;
    const b = @intFromPtr(bytes.ptr);
    const a = @intFromPtr(items.ptr);
    if (items.len != 0 and b >= a and b + bytes.len <= a + items.len) {
        return .{ .slice = .{ .offset = @intCast(b - a), .len = @intCast(bytes.len) } };
    }
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.appendSlice(vm.allocator, bytes);
    return .{ .slice = .{ .offset = offset, .len = @intCast(bytes.len) } };
}

/// Append a string value onto the arena. Slice sources are copied by offset so
/// a realloc of `string_bytes` cannot invalidate the source.
pub fn appendStr(vm: *VMState, v: Value) !void {
    switch (v) {
        .slice => |s| {
            if (s.len == 0) return;
            try vm.string_bytes.ensureUnusedCapacity(vm.allocator, s.len);
            const src = vm.string_bytes.items[s.offset .. s.offset + s.len];
            vm.string_bytes.appendSliceAssumeCapacity(src);
        },
        .name => |idx| try vm.string_bytes.appendSlice(vm.allocator, vm.chunk.stringAt(idx)),
        .ptr => |p| {
            const len: usize = @intCast(vm.memory[@intCast(p - 1)].int);
            try vm.string_bytes.ensureUnusedCapacity(vm.allocator, len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const val = vm.memory[@intCast(p + @as(i32, @intCast(i)))];
                if (val != .int) return error.TypeError;
                vm.string_bytes.appendAssumeCapacity(@intCast(val.int));
            }
        },
        else => return error.TypeError,
    }
}

/// Allocate an error object `[ERROR_TAG, codePtr, payload]` and return ptr to codePtr slot.
pub fn makeError(vm: *VMState, msg: []const u8) !Value {
    const msg_val = try writeSlice(vm, msg);
    const p = try vm.allocImmortal(3);
    vm.memory[@intCast(p)] = .{ .int = ERROR_TAG };
    vm.memory[@intCast(p + 1)] = msg_val;
    vm.memory[@intCast(p + 2)] = .null;
    return .{ .ptr = p + 1 };
}

pub fn makeErrorWithPayload(vm: *VMState, msg: []const u8, payload: Value) !Value {
    const msg_val = try writeSlice(vm, msg);
    const p = try vm.allocImmortal(3);
    vm.memory[@intCast(p)] = .{ .int = ERROR_TAG };
    vm.memory[@intCast(p + 1)] = msg_val;
    vm.memory[@intCast(p + 2)] = payload;
    return .{ .ptr = p + 1 };
}

/// Map common filesystem Zig errors to stable LLTS error codes.
pub fn ioErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "FileNotFound",
        error.AccessDenied => "AccessDenied",
        error.IsDir => "IsDir",
        error.NotDir => "NotDir",
        error.PathAlreadyExists => "PathAlreadyExists",
        error.FileBusy => "FileBusy",
        error.SharingViolation => "SharingViolation",
        else => "IoError",
    };
}

pub fn makeIoError(vm: *VMState, err: anyerror, path: []const u8) !Value {
    return makeErrorWithPayload(vm, ioErrorCode(err), try writeSlice(vm, path));
}

/// Write an array of i32 values (length-prefixed); returns data pointer.
/// Immortal: returned from natives like `__split` through LLTS wrappers.
/// Heap addresses are stored as `.ptr` so `print` / string ops see strings, not raw ints.
pub fn writeArray(vm: *VMState, items: []const Value) !Value {
    const len: i64 = @intCast(items.len);
    const base = try vm.allocImmortal(@intCast(len + 1));
    vm.memory[@intCast(base)] = .{ .int = len };
    for (items, 0..) |item, i| {
        vm.memory[@intCast(base + 1 + @as(i32, @intCast(i)))] = item;
    }
    return .{ .ptr = base + 1 };
}

pub fn asInt(v: Value) !i64 {
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
        .int => |n| if (n >= state_mod.HEAP_START) @intCast(n) else error.TypeError,
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

/// Zero-allocation slice getter. Arena slices and interned names are views;
/// heap ptr strings are copied into `buf`.
/// Do not grow `vm.string_bytes` while holding a `.slice` view.
pub fn valueToStr(vm: *VMState, v: Value, buf: *std.ArrayList(u8)) ![]const u8 {
    switch (v) {
        .name => |idx| return vm.chunk.stringAt(idx),
        .slice => |s| return vm.string_bytes.items[s.offset .. s.offset + s.len],
        .ptr => |p| {
            buf.clearRetainingCapacity();
            const len: usize = @intCast(vm.memory[@intCast(p - 1)].int);
            try buf.ensureTotalCapacity(vm.allocator, len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const val = vm.memory[@intCast(p + @as(i32, @intCast(i)))];
                switch (val) {
                    .int => |ch| buf.appendAssumeCapacity(@intCast(ch)),
                    else => return error.TypeError,
                }
            }
            return buf.items;
        },
        else => return error.TypeError,
    }
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
            .ptr => |p| blk: {
                const val = vm.memory[@intCast(p + @as(i32, @intCast(i)))];
                if (val != .int) return false;
                break :blk @intCast(val.int);
            },
            else => unreachable,
        };
        const char_b: u8 = switch (b) {
            .slice => |s| vm.string_bytes.items[s.offset + i],
            .name => |idx| vm.chunk.stringAt(idx)[i],
            .ptr => |p| blk: {
                const val = vm.memory[@intCast(p + @as(i32, @intCast(i)))];
                if (val != .int) return false;
                break :blk @intCast(val.int);
            },
            else => unreachable,
        };
        if (char_a != char_b) return false;
    }
    
    return true;
}
