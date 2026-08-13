const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var buffer_alloc_n: NativeFunction = undefined;
var buffer_create_n: NativeFunction = undefined;
var buffer_write_string_n: NativeFunction = undefined;
var buffer_append_string_n: NativeFunction = undefined;
var buffer_read_string_n: NativeFunction = undefined;
var buffer_len_n: NativeFunction = undefined;
var buffer_get_n: NativeFunction = undefined;
var buffer_set_n: NativeFunction = undefined;
var buffer_push_n: NativeFunction = undefined;
var buffer_from_string_n: NativeFunction = undefined;
var buffer_copy_n: NativeFunction = undefined;
var buffer_fill_n: NativeFunction = undefined;
var buffer_fill_range_n: NativeFunction = undefined;
var buffer_resize_n: NativeFunction = undefined;

fn bufferAlloc(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const size = try util.asInt(args[0]);
    if (size < 0) return error.IndexOutOfBounds;
    
    const buf = try vm.allocBuffer();
    try buf.bytes.appendNTimes(vm.allocator, 0, @intCast(size));
    return .{ .buffer = buf };
}

fn bufferCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const buf = try vm.allocBuffer();
    return .{ .buffer = buf };
}

fn bufferWriteString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const offset_raw = try util.asInt(args[1]);
    if (offset_raw < 0) return error.IndexOutOfBounds;
    const offset: usize = @intCast(offset_raw);
    
    var buf_tmp: std.ArrayList(u8) = .empty; defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[2], &buf_tmp);
    
    const buf = args[0].buffer;
    const end = std.math.add(usize, offset, str.len) catch return error.IndexOutOfBounds;
    if (end > buf.bytes.items.len) {
        return error.IndexOutOfBounds;
    }
    
    @memcpy(buf.bytes.items[offset .. offset + str.len], str);
    return .{ .int = @intCast(str.len) };
}

fn bufferAppendString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    
    var buf_tmp: std.ArrayList(u8) = .empty; defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[1], &buf_tmp);
    
    const buf = args[0].buffer;
    try buf.bytes.appendSlice(vm.allocator, str);
    return .{ .int = @intCast(str.len) };
}

fn bufferReadString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    
    const offset_raw = try util.asInt(args[1]);
    const len_raw = try util.asInt(args[2]);
    if (offset_raw < 0 or len_raw < 0) return error.IndexOutOfBounds;
    const offset: usize = @intCast(offset_raw);
    const len: usize = @intCast(len_raw);
    
    const buf = args[0].buffer;
    const end = std.math.add(usize, offset, len) catch return error.IndexOutOfBounds;
    if (end > buf.bytes.items.len) {
        return error.IndexOutOfBounds;
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

fn bufferGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const index_raw = try util.asInt(args[1]);
    if (index_raw < 0) return error.IndexOutOfBounds;
    const index: usize = @intCast(index_raw);
    
    const buf = args[0].buffer;
    if (index >= buf.bytes.items.len) return error.IndexOutOfBounds;
    return .{ .int = @intCast(buf.bytes.items[index]) };
}

fn bufferSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const index_raw = try util.asInt(args[1]);
    const val_raw = try util.asInt(args[2]);
    if (index_raw < 0) return error.IndexOutOfBounds;
    const index: usize = @intCast(index_raw);
    
    const buf = args[0].buffer;
    if (index >= buf.bytes.items.len) return error.IndexOutOfBounds;
    buf.bytes.items[index] = @intCast(val_raw & 0xFF);
    return .null;
}

fn bufferPush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const val_raw = try util.asInt(args[1]);
    
    const buf = args[0].buffer;
    try buf.bytes.append(vm.allocator, @intCast(val_raw & 0xFF));
    return .null;
}

fn bufferFromString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    var buf_tmp: std.ArrayList(u8) = .empty; defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf_tmp);
    
    const buf = try vm.allocBuffer();
    try buf.bytes.appendSlice(vm.allocator, str);
    return .{ .buffer = buf };
}

fn bufferFillRange(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = vm;
    if (args.len < 4) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const val_raw = try util.asInt(args[1]);
    const val: u8 = @intCast(val_raw & 0xFF);
    const start_raw = try util.asInt(args[2]);
    const len_raw = try util.asInt(args[3]);
    if (start_raw < 0 or len_raw < 0) return error.IndexOutOfBounds;
    const start: usize = @intCast(start_raw);
    const len: usize = @intCast(len_raw);
    const end = std.math.add(usize, start, len) catch return error.IndexOutOfBounds;
    const buf = args[0].buffer;
    if (end > buf.bytes.items.len) return error.IndexOutOfBounds;
    
    @memset(buf.bytes.items[start .. end], val);
    return .null;
}

fn bufferCopy(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 5) return error.ArityError;
    if (args[0] != .buffer or args[2] != .buffer) return error.TypeError;
    const dst = args[0].buffer;
    const src = args[2].buffer;
    
    const dst_off = try util.asInt(args[1]);
    const src_off = try util.asInt(args[3]);
    const len = try util.asInt(args[4]);
    if (dst_off < 0 or src_off < 0 or len < 0) return error.IndexOutOfBounds;
    
    const u_dst_off: usize = @intCast(dst_off);
    const u_src_off: usize = @intCast(src_off);
    const u_len: usize = @intCast(len);
    
    const dst_end = std.math.add(usize, u_dst_off, u_len) catch return error.IndexOutOfBounds;
    const src_end = std.math.add(usize, u_src_off, u_len) catch return error.IndexOutOfBounds;
    
    if (dst_end > dst.bytes.items.len or src_end > src.bytes.items.len) {
        return error.IndexOutOfBounds;
    }
    
    if (dst == src and u_dst_off != u_src_off) {
        if (u_dst_off < u_src_off) {
            std.mem.copyForwards(u8, dst.bytes.items[u_dst_off .. dst_end], src.bytes.items[u_src_off .. src_end]);
        } else {
            std.mem.copyBackwards(u8, dst.bytes.items[u_dst_off .. dst_end], src.bytes.items[u_src_off .. src_end]);
        }
    } else if (dst != src) {
        @memcpy(dst.bytes.items[u_dst_off .. dst_end], src.bytes.items[u_src_off .. src_end]);
    }
    return .null;
}

fn bufferFill(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const val_raw = try util.asInt(args[1]);
    const val: u8 = @intCast(val_raw & 0xFF);
    
    const buf = args[0].buffer;
    @memset(buf.bytes.items, val);
    return .null;
}

fn bufferResize(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const new_len = try util.asInt(args[1]);
    if (new_len < 0) return error.IndexOutOfBounds;
    
    const buf = args[0].buffer;
    const old_len = buf.bytes.items.len;
    try buf.bytes.resize(vm.allocator, @intCast(new_len));
    if (new_len > old_len) {
        @memset(buf.bytes.items[old_len..@intCast(new_len)], 0);
    }
    return .null;
}

pub fn register(vm: *VMState) !void {
    buffer_alloc_n = .{ .name = "__bufferAlloc", .func = bufferAlloc, .arity = 1 };
    buffer_create_n = .{ .name = "__bufferCreate", .func = bufferCreate, .arity = 0 };
    buffer_write_string_n = .{ .name = "__bufferWriteString", .func = bufferWriteString, .arity = 3 };
    buffer_append_string_n = .{ .name = "__bufferAppendString", .func = bufferAppendString, .arity = 2 };
    buffer_read_string_n = .{ .name = "__bufferReadString", .func = bufferReadString, .arity = 3 };
    buffer_len_n = .{ .name = "__bufferLen", .func = bufferLen, .arity = 1 };
    buffer_get_n = .{ .name = "__bufferGet", .func = bufferGet, .arity = 2 };
    buffer_set_n = .{ .name = "__bufferSet", .func = bufferSet, .arity = 3 };
    buffer_push_n = .{ .name = "__bufferPush", .func = bufferPush, .arity = 2 };
    buffer_from_string_n = .{ .name = "__bufferFromString", .func = bufferFromString, .arity = 1 };
    buffer_copy_n = .{ .name = "__bufferCopy", .func = bufferCopy, .arity = 5 };
    buffer_fill_n = .{ .name = "__bufferFill", .func = bufferFill, .arity = 2 };
    buffer_fill_range_n = .{ .name = "__bufferFillRange", .func = bufferFillRange, .arity = 4 };
    buffer_resize_n = .{ .name = "__bufferResize", .func = bufferResize, .arity = 2 };

    try vm.globals.put("__bufferAlloc", .{ .native = &buffer_alloc_n });
    try vm.globals.put("__bufferCreate", .{ .native = &buffer_create_n });
    try vm.globals.put("__bufferWriteString", .{ .native = &buffer_write_string_n });
    try vm.globals.put("__bufferAppendString", .{ .native = &buffer_append_string_n });
    try vm.globals.put("__bufferReadString", .{ .native = &buffer_read_string_n });
    try vm.globals.put("__bufferLen", .{ .native = &buffer_len_n });
    try vm.globals.put("__bufferGet", .{ .native = &buffer_get_n });
    try vm.globals.put("__bufferSet", .{ .native = &buffer_set_n });
    try vm.globals.put("__bufferPush", .{ .native = &buffer_push_n });
    try vm.globals.put("__bufferFromString", .{ .native = &buffer_from_string_n });
    try vm.globals.put("__bufferCopy", .{ .native = &buffer_copy_n });
    try vm.globals.put("__bufferFill", .{ .native = &buffer_fill_n });
    try vm.globals.put("__bufferFillRange", .{ .native = &buffer_fill_range_n });
    try vm.globals.put("__bufferResize", .{ .native = &buffer_resize_n });
}
