const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");
const mem = @import("mem.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;
const BytesRef = value.BytesRef;

var buffer_alloc_n: NativeFunction = undefined;
var buffer_create_n: NativeFunction = undefined;
var buffer_create_immortal_n: NativeFunction = undefined;
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

fn arenaOpt(ctrl: i32) ?Value {
    if (ctrl == 0) return null;
    return .{ .ptr = ctrl };
}

fn dataSlice(vm: *VMState, d: BytesRef) []u8 {
    if (d.len == 0) return vm.bytes.items[0..0];
    return vm.bytes.items[d.offset..][0..d.len];
}

fn ensure(vm: *VMState, buf: *value.BufferObject, min_cap: u32) !void {
    try mem.requireContainerArena(vm, buf.arena_ctrl, buf.arena_gen, "__bufferEnsure");
    buf.data = try mem.ensureBytesCapacity(vm, buf.arena_ctrl, arenaOpt(buf.arena_ctrl), buf.data, min_cap);
}

fn bufferAlloc(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const size = try util.asInt(args[1]);
    if (size < 0) return error.IndexOutOfBounds;
    const ctrl = try mem.resolveArena(vm, args[0]);
    try mem.requireArenaAlive(vm, ctrl, "__bufferAlloc");
    const buf = try vm.allocBuffer();
    buf.arena_ctrl = ctrl;
    buf.arena_gen = mem.arenaGeneration(vm, ctrl);
    buf.data = try mem.allocBytesInArena(vm, args[0], @intCast(size), @intCast(size));
    return .{ .buffer = buf };
}

fn bufferCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const ctrl = try mem.resolveArena(vm, args[0]);
    try mem.requireArenaAlive(vm, ctrl, "__bufferCreate");
    const buf = try vm.allocBuffer();
    buf.arena_ctrl = ctrl;
    buf.arena_gen = mem.arenaGeneration(vm, ctrl);
    buf.data = try mem.allocBytesInArena(vm, args[0], 0, 64);
    return .{ .buffer = buf };
}

/// Escape hatch for fs/io: growable on immortal byte heap (not arena-resettable).
fn bufferCreateImmortal(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const buf = try vm.allocBuffer();
    buf.arena_ctrl = 0;
    buf.arena_gen = 0;
    buf.data = try mem.allocBytesImmortal(vm, 0, 64);
    return .{ .buffer = buf };
}

fn bufferWriteString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const offset_raw = try util.asInt(args[1]);
    if (offset_raw < 0) return error.IndexOutOfBounds;
    const offset: usize = @intCast(offset_raw);

    var buf_tmp: std.ArrayList(u8) = .empty;
    defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[2], &buf_tmp);

    const buf = args[0].buffer;
    try mem.requireContainerArena(vm, buf.arena_ctrl, buf.arena_gen, "__bufferWriteString");
    const end = std.math.add(usize, offset, str.len) catch return error.IndexOutOfBounds;
    if (end > buf.data.len) return error.IndexOutOfBounds;
    @memcpy(dataSlice(vm, buf.data)[offset .. offset + str.len], str);
    return .{ .i64 = @intCast(str.len) };
}

fn bufferAppendString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;

    var buf_tmp: std.ArrayList(u8) = .empty;
    defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[1], &buf_tmp);

    const buf = args[0].buffer;
    const new_len: u32 = @intCast(buf.data.len + str.len);
    try ensure(vm, buf, new_len);
    @memcpy(vm.bytes.items[buf.data.offset + buf.data.len ..][0..str.len], str);
    buf.data.len = new_len;
    return .{ .i64 = @intCast(str.len) };
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
    try mem.requireContainerArena(vm, buf.arena_ctrl, buf.arena_gen, "__bufferReadString");
    const end = std.math.add(usize, offset, len) catch return error.IndexOutOfBounds;
    if (end > buf.data.len) return error.IndexOutOfBounds;
    return try util.writeSlice(vm, dataSlice(vm, buf.data)[offset .. offset + len]);
}

fn bufferLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    try mem.requireContainerArena(vm, args[0].buffer.arena_ctrl, args[0].buffer.arena_gen, "__bufferLen");
    return .{ .i64 = @intCast(args[0].buffer.data.len) };
}

fn bufferGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    try mem.requireContainerArena(vm, args[0].buffer.arena_ctrl, args[0].buffer.arena_gen, "__bufferGet");
    const index_raw = try util.asInt(args[1]);
    if (index_raw < 0) return error.IndexOutOfBounds;
    const index: usize = @intCast(index_raw);

    const buf = args[0].buffer;
    if (index >= buf.data.len) return error.IndexOutOfBounds;
    return .{ .i64 = @intCast(dataSlice(vm, buf.data)[index]) };
}

fn bufferSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    try mem.requireContainerArena(vm, args[0].buffer.arena_ctrl, args[0].buffer.arena_gen, "__bufferSet");
    const index_raw = try util.asInt(args[1]);
    const val_raw = try util.asInt(args[2]);
    if (index_raw < 0) return error.IndexOutOfBounds;
    const index: usize = @intCast(index_raw);

    const buf = args[0].buffer;
    if (index >= buf.data.len) return error.IndexOutOfBounds;
    dataSlice(vm, buf.data)[index] = @intCast(val_raw & 0xFF);
    return .null;
}

fn bufferPush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const val_raw = try util.asInt(args[1]);

    const buf = args[0].buffer;
    try ensure(vm, buf, buf.data.len + 1);
    vm.bytes.items[buf.data.offset + buf.data.len] = @intCast(val_raw & 0xFF);
    buf.data.len += 1;
    return .null;
}

fn bufferFromString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    var buf_tmp: std.ArrayList(u8) = .empty;
    defer buf_tmp.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[1], &buf_tmp);

    const ctrl = try mem.resolveArena(vm, args[0]);
    try mem.requireArenaAlive(vm, ctrl, "__bufferFromString");
    const buf = try vm.allocBuffer();
    buf.arena_ctrl = ctrl;
    buf.arena_gen = mem.arenaGeneration(vm, ctrl);
    buf.data = try mem.allocBytesInArena(vm, args[0], @intCast(str.len), @intCast(str.len));
    if (str.len > 0) @memcpy(dataSlice(vm, buf.data), str);
    return .{ .buffer = buf };
}

fn bufferFillRange(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
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
    try mem.requireContainerArena(vm, buf.arena_ctrl, buf.arena_gen, "__bufferFillRange");
    if (end > buf.data.len) return error.IndexOutOfBounds;
    @memset(dataSlice(vm, buf.data)[start..end], val);
    return .null;
}

fn bufferCopy(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 5) return error.ArityError;
    if (args[0] != .buffer or args[2] != .buffer) return error.TypeError;
    const dst = args[0].buffer;
    const src = args[2].buffer;
    try mem.requireContainerArena(vm, dst.arena_ctrl, dst.arena_gen, "__bufferCopy");
    try mem.requireContainerArena(vm, src.arena_ctrl, src.arena_gen, "__bufferCopy");

    const dst_off = try util.asInt(args[1]);
    const src_off = try util.asInt(args[3]);
    const len = try util.asInt(args[4]);
    if (dst_off < 0 or src_off < 0 or len < 0) return error.IndexOutOfBounds;

    const u_dst_off: usize = @intCast(dst_off);
    const u_src_off: usize = @intCast(src_off);
    const u_len: usize = @intCast(len);

    const dst_end = std.math.add(usize, u_dst_off, u_len) catch return error.IndexOutOfBounds;
    const src_end = std.math.add(usize, u_src_off, u_len) catch return error.IndexOutOfBounds;

    if (dst_end > dst.data.len or src_end > src.data.len) return error.IndexOutOfBounds;

    const dst_sl = dataSlice(vm, dst.data);
    const src_sl = dataSlice(vm, src.data);
    if (dst == src and u_dst_off != u_src_off) {
        if (u_dst_off < u_src_off) {
            std.mem.copyForwards(u8, dst_sl[u_dst_off..dst_end], src_sl[u_src_off..src_end]);
        } else {
            std.mem.copyBackwards(u8, dst_sl[u_dst_off..dst_end], src_sl[u_src_off..src_end]);
        }
    } else if (dst != src) {
        @memcpy(dst_sl[u_dst_off..dst_end], src_sl[u_src_off..src_end]);
    }
    return .null;
}

fn bufferFill(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    try mem.requireContainerArena(vm, args[0].buffer.arena_ctrl, args[0].buffer.arena_gen, "__bufferFill");
    const val_raw = try util.asInt(args[1]);
    const val: u8 = @intCast(val_raw & 0xFF);
    @memset(dataSlice(vm, args[0].buffer.data), val);
    return .null;
}

fn bufferResize(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .buffer) return error.TypeError;
    const new_len = try util.asInt(args[1]);
    if (new_len < 0) return error.IndexOutOfBounds;

    const buf = args[0].buffer;
    const old_len = buf.data.len;
    const nl: u32 = @intCast(new_len);
    try ensure(vm, buf, nl);
    if (nl > old_len) {
        @memset(vm.bytes.items[buf.data.offset + old_len ..][0 .. nl - old_len], 0);
    }
    buf.data.len = nl;
    return .null;
}

pub fn register(vm: *VMState) !void {
    buffer_alloc_n = .{ .name = "__bufferAlloc", .func = bufferAlloc, .arity = 2 };
    buffer_create_n = .{ .name = "__bufferCreate", .func = bufferCreate, .arity = 1 };
    buffer_create_immortal_n = .{ .name = "__bufferCreateImmortal", .func = bufferCreateImmortal, .arity = 0 };
    buffer_write_string_n = .{ .name = "__bufferWriteString", .func = bufferWriteString, .arity = 3 };
    buffer_append_string_n = .{ .name = "__bufferAppendString", .func = bufferAppendString, .arity = 2 };
    buffer_read_string_n = .{ .name = "__bufferReadString", .func = bufferReadString, .arity = 3 };
    buffer_len_n = .{ .name = "__bufferLen", .func = bufferLen, .arity = 1 };
    buffer_get_n = .{ .name = "__bufferGet", .func = bufferGet, .arity = 2 };
    buffer_set_n = .{ .name = "__bufferSet", .func = bufferSet, .arity = 3 };
    buffer_push_n = .{ .name = "__bufferPush", .func = bufferPush, .arity = 2 };
    buffer_from_string_n = .{ .name = "__bufferFromString", .func = bufferFromString, .arity = 2 };
    buffer_copy_n = .{ .name = "__bufferCopy", .func = bufferCopy, .arity = 5 };
    buffer_fill_n = .{ .name = "__bufferFill", .func = bufferFill, .arity = 2 };
    buffer_fill_range_n = .{ .name = "__bufferFillRange", .func = bufferFillRange, .arity = 4 };
    buffer_resize_n = .{ .name = "__bufferResize", .func = bufferResize, .arity = 2 };

    try vm.defineGlobal("__bufferAlloc", .{ .native = &buffer_alloc_n });
    try vm.defineGlobal("__bufferCreate", .{ .native = &buffer_create_n });
    try vm.defineGlobal("__bufferCreateImmortal", .{ .native = &buffer_create_immortal_n });
    try vm.defineGlobal("__bufferWriteString", .{ .native = &buffer_write_string_n });
    try vm.defineGlobal("__bufferAppendString", .{ .native = &buffer_append_string_n });
    try vm.defineGlobal("__bufferReadString", .{ .native = &buffer_read_string_n });
    try vm.defineGlobal("__bufferLen", .{ .native = &buffer_len_n });
    try vm.defineGlobal("__bufferGet", .{ .native = &buffer_get_n });
    try vm.defineGlobal("__bufferSet", .{ .native = &buffer_set_n });
    try vm.defineGlobal("__bufferPush", .{ .native = &buffer_push_n });
    try vm.defineGlobal("__bufferFromString", .{ .native = &buffer_from_string_n });
    try vm.defineGlobal("__bufferCopy", .{ .native = &buffer_copy_n });
    try vm.defineGlobal("__bufferFill", .{ .native = &buffer_fill_n });
    try vm.defineGlobal("__bufferFillRange", .{ .native = &buffer_fill_range_n });
    try vm.defineGlobal("__bufferResize", .{ .native = &buffer_resize_n });
}
