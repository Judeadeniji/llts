const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var buffer_alloc_n: NativeFunction = undefined;
var buffer_write_string_n: NativeFunction = undefined;
var buffer_read_string_n: NativeFunction = undefined;
var buffer_len_n: NativeFunction = undefined;
var buffer_free_n: NativeFunction = undefined;
var buffer_get_n: NativeFunction = undefined;
var buffer_set_n: NativeFunction = undefined;

fn bufferAlloc(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const size = try util.asInt(args[0]);
    if (size < 0) return try util.makeError(vm, "Invalid buffer size");
    
    const buf = try vm.allocBuffer();
    try buf.bytes.appendNTimes(vm.allocator, 0, @intCast(size));
    return .{ .buffer = buf };
}

fn bufferWriteString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const offset_raw = try util.asInt(args[1]);
    if (offset_raw < 0) return try util.makeError(vm, "Invalid offset");
    const offset: usize = @intCast(offset_raw);
    
    var buf_tmp: std.ArrayList(u8) = .empty; defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[2], &buf_tmp);
    
    const buf = args[0].buffer;
    if (offset + str.len > buf.bytes.items.len) {
        return try util.makeError(vm, "Buffer write out of bounds");
    }
    
    @memcpy(buf.bytes.items[offset .. offset + str.len], str);
    return .{ .int = @intCast(str.len) };
}

fn bufferReadString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    
    const offset_raw = try util.asInt(args[1]);
    const len_raw = try util.asInt(args[2]);
    if (offset_raw < 0 or len_raw < 0) return try util.makeError(vm, "Invalid offset or length");
    const offset: usize = @intCast(offset_raw);
    const len: usize = @intCast(len_raw);
    
    const buf = args[0].buffer;
    if (offset + len > buf.bytes.items.len) {
        return try util.makeError(vm, "Buffer read out of bounds");
    }
    
    const slice = buf.bytes.items[offset .. offset + len];
    return try util.writeSlice(vm, slice);
}

fn bufferLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    return .{ .int = @intCast(args[0].buffer.bytes.items.len) };
}

fn bufferFree(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    
    const buf = args[0].buffer;
    var found = false;
    for (vm.buffers.items, 0..) |b, i| {
        if (b == buf) {
            _ = vm.buffers.swapRemove(i);
            found = true;
            break;
        }
    }
    
    if (found) {
        buf.deinit(vm.allocator);
        vm.allocator.destroy(buf);
    }
    return .null;
}

fn bufferGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const index_raw = try util.asInt(args[1]);
    if (index_raw < 0) return try util.makeError(vm, "Invalid offset");
    const index: usize = @intCast(index_raw);
    
    const buf = args[0].buffer;
    if (index >= buf.bytes.items.len) return try util.makeError(vm, "Buffer read out of bounds");
    return .{ .int = @intCast(buf.bytes.items[index]) };
}

fn bufferSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const index_raw = try util.asInt(args[1]);
    const val_raw = try util.asInt(args[2]);
    if (index_raw < 0) return try util.makeError(vm, "Invalid offset");
    const index: usize = @intCast(index_raw);
    
    const buf = args[0].buffer;
    if (index >= buf.bytes.items.len) return try util.makeError(vm, "Buffer write out of bounds");
    buf.bytes.items[index] = @intCast(val_raw & 0xFF);
    return .null;
}

pub fn register(vm: *VMState) !void {
    buffer_alloc_n = .{ .name = "__bufferAlloc", .func = bufferAlloc, .arity = 1 };
    buffer_write_string_n = .{ .name = "__bufferWriteString", .func = bufferWriteString, .arity = 3 };
    buffer_read_string_n = .{ .name = "__bufferReadString", .func = bufferReadString, .arity = 3 };
    buffer_len_n = .{ .name = "__bufferLen", .func = bufferLen, .arity = 1 };
    buffer_free_n = .{ .name = "__bufferFree", .func = bufferFree, .arity = 1 };
    buffer_get_n = .{ .name = "__bufferGet", .func = bufferGet, .arity = 2 };
    buffer_set_n = .{ .name = "__bufferSet", .func = bufferSet, .arity = 3 };
    
    try vm.globals.put("__bufferAlloc", .{ .native = &buffer_alloc_n });
    try vm.globals.put("__bufferWriteString", .{ .native = &buffer_write_string_n });
    try vm.globals.put("__bufferReadString", .{ .native = &buffer_read_string_n });
    try vm.globals.put("__bufferLen", .{ .native = &buffer_len_n });
    try vm.globals.put("__bufferFree", .{ .native = &buffer_free_n });
    try vm.globals.put("__bufferGet", .{ .native = &buffer_get_n });
    try vm.globals.put("__bufferSet", .{ .native = &buffer_set_n });
}
