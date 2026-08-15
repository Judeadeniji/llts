const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const ERROR_TAG = state_mod.ERROR_TAG;

/// Read a length-prefixed heap string at `ptr` into an owned buffer.
pub fn readString(vm: *VMState, ptr: i32) ![]u8 {
    if (ptr < 1 or !vm.isValidHeapPtr(ptr)) return error.TypeError;
    const len: usize = @intCast(vm.slot(ptr - 1).*.i64);
    const buf = try vm.allocator.alloc(u8, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const val = vm.slot(ptr + @as(i32, @intCast(i))).*;
        switch (val) {
            .i64 => |ch| buf[i] = @intCast(ch),
            else => {
                vm.allocator.free(buf);
                return error.TypeError;
            }
        }
    }
    return buf;
}

/// Allocate a length-prefixed string; packed via the unified byte heap (not Value-per-byte).
pub fn writeString(vm: *VMState, bytes: []const u8) !Value {
    return writeSlice(vm, bytes);
}

/// Appends string bytes to the packed immortal region and returns a string slice.
/// If `bytes` already lives in the packed heap, returns a view (no copy).
pub fn writeSlice(vm: *VMState, bytes: []const u8) !Value {
    if (bytes.len == 0) return .{ .slice = .{ .offset = 0, .len = 0 } };
    const items = vm.bytes.items;
    const b = @intFromPtr(bytes.ptr);
    const a = @intFromPtr(items.ptr);
    if (items.len != 0 and b >= a and b + bytes.len <= a + items.len) {
        return .{ .slice = .{ .offset = @intCast(b - a), .len = @intCast(bytes.len) } };
    }
    const offset = try vm.appendImmortal(bytes);
    return .{ .slice = .{ .offset = offset, .len = @intCast(bytes.len) } };
}

/// Append a string value onto the packed heap. Slice sources are copied by offset so
/// a realloc of `bytes` cannot invalidate the source.
pub fn appendStr(vm: *VMState, v: Value) !void {
    switch (v) {
        .slice => |s| {
            if (s.len == 0) return;
            try vm.ensurePackedCapacity(s.len);
            const src = vm.bytes.items[s.offset .. s.offset + s.len];
            vm.bytes.appendSliceAssumeCapacity(src);
            vm.noteImmortalGrowth();
        },
        .bytes => |b| {
            try vm.ensurePackedCapacity(b.len);
            const src = vm.bytes.items[b.offset..][0..b.len];
            vm.bytes.appendSliceAssumeCapacity(src);
            vm.noteImmortalGrowth();
        },
        .name => |idx| {
            const data = vm.chunk.stringAt(idx);
            _ = try vm.appendImmortal(data);
        },
        .ptr => |p| {
            const len: usize = @intCast(vm.slot(p - 1).*.i64);
            try vm.ensurePackedCapacity(len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const val = vm.slot(p + @as(i32, @intCast(i))).*;
                if (val != .i64) return error.TypeError;
                vm.bytes.appendAssumeCapacity(@intCast(val.i64));
            }
            vm.noteImmortalGrowth();
        },
        else => return error.TypeError,
    }
}

/// Allocate an error object `[ERROR_TAG, codePtr, payload]` and return ptr to codePtr slot.
pub fn makeError(vm: *VMState, msg: []const u8) !Value {
    const msg_val = try writeSlice(vm, msg);
    const p = try vm.allocImmortal(3);
    vm.slot(p).* = .{ .i64 = ERROR_TAG };
    vm.slot(p + 1).* = msg_val;
    vm.slot(p + 2).* = .null;
    return .{ .ptr = p + 1 };
}

pub fn makeErrorWithPayload(vm: *VMState, msg: []const u8, payload: Value) !Value {
    const msg_val = try writeSlice(vm, msg);
    const p = try vm.allocImmortal(3);
    vm.slot(p).* = .{ .i64 = ERROR_TAG };
    vm.slot(p + 1).* = msg_val;
    vm.slot(p + 2).* = payload;
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

/// Write an array of values into a packed immortal `.array`.
pub fn writeArray(vm: *VMState, items: []const Value) !Value {
    const arr_v = try vm.allocImmortalArray(@intCast(items.len));
    const a = arr_v.array;
    for (items, 0..) |item, i| {
        vm.arrayElemPtr(a, @intCast(i)).* = item;
    }
    return arr_v;
}

pub fn asInt(v: Value) !i64 {
    return @import("../../compiler/widths.zig").valueAsI64(v) orelse error.TypeError;
}

pub fn asPtr(v: Value) !i32 {
    return switch (v) {
        .ptr => |p| p,
        .i64 => |n| if (n >= state_mod.HEAP_START) @intCast(n) else error.TypeError,
        else => error.TypeError,
    };
}

/// Read string from a Value that is either a heap ptr or interned name.
pub fn valueToOwnedString(vm: *VMState, v: Value) ![]u8 {
    return switch (v) {
        .ptr => |p| try readString(vm, p),
        .name => |idx| try vm.allocator.dupe(u8, vm.chunk.stringAt(idx)),
        .slice => |s| try vm.allocator.dupe(u8, vm.bytes.items[s.offset .. s.offset + s.len]),
        .bytes => |b| try vm.allocator.dupe(u8, vm.bytes.items[b.offset..][0..b.len]),
        else => error.TypeError,
    };
}

/// Zero-allocation slice getter. Packed slices and interned names are views;
/// heap ptr strings are copied into `buf`.
/// Do not grow `vm.bytes` while holding a `.slice` view.
pub fn valueToStr(vm: *VMState, v: Value, buf: *std.ArrayList(u8)) ![]const u8 {
    switch (v) {
        .name => |idx| return vm.chunk.stringAt(idx),
        .slice => |s| return vm.bytes.items[s.offset .. s.offset + s.len],
        .bytes => |b| return vm.bytes.items[b.offset..][0..b.len],
        .ptr => |p| {
            buf.clearRetainingCapacity();
            const len: usize = @intCast(vm.slot(p - 1).*.i64);
            try buf.ensureTotalCapacity(vm.allocator, len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const val = vm.slot(p + @as(i32, @intCast(i))).*;
                switch (val) {
                    .i64 => |ch| buf.appendAssumeCapacity(@intCast(ch)),
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
    const is_str_a = a == .name or a == .slice or a == .ptr or a == .bytes;
    const is_str_b = b == .name or b == .slice or b == .ptr or b == .bytes;
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
        .bytes => |ba| ba.len,
        .name => |idx| vm.chunk.stringAt(idx).len,
        .ptr => |p| @intCast(vm.slot(p - 1).*.i64),
        else => unreachable,
    };
    
    const len_b: usize = switch (b) {
        .slice => |s| s.len,
        .bytes => |by| by.len,
        .name => |idx| vm.chunk.stringAt(idx).len,
        .ptr => |p| @intCast(vm.slot(p - 1).*.i64),
        else => unreachable,
    };
    
    if (len_a != len_b) return false;
    
    // Fallback: byte-by-byte comparison
    var i: usize = 0;
    while (i < len_a) : (i += 1) {
        const char_a: u8 = switch (a) {
            .slice => |s| vm.bytes.items[s.offset + i],
            .bytes => |by| vm.bytes.items[by.offset + i],
            .name => |idx| vm.chunk.stringAt(idx)[i],
            .ptr => |p| blk: {
                const val = vm.slot(p + @as(i32, @intCast(i))).*;
                if (val != .i64) return false;
                break :blk @intCast(val.i64);
            },
            else => unreachable,
        };
        const char_b: u8 = switch (b) {
            .slice => |s| vm.bytes.items[s.offset + i],
            .bytes => |by| vm.bytes.items[by.offset + i],
            .name => |idx| vm.chunk.stringAt(idx)[i],
            .ptr => |p| blk: {
                const val = vm.slot(p + @as(i32, @intCast(i))).*;
                if (val != .i64) return false;
                break :blk @intCast(val.i64);
            },
            else => unreachable,
        };
        if (char_a != char_b) return false;
    }
    
    return true;
}
