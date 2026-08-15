const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const runtime = @import("../../errors/runtime.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

/// Control-block magic (Arena.handle → control).
const ARENA_MAGIC: i32 = 0xa5ea;
/// Per-chunk magic (linked bump buffers, Zig ArenaAllocator-style).
const CHUNK_MAGIC: i32 = 0xc111;
/// Packed-byte chunk header (data lives in `vm.bytes`).
const BYTE_CHUNK_MAGIC: i32 = 0xb10c;

/// Default first-chunk data slots when create(0) / tiny hint.
const DEFAULT_CHUNK: i32 = 64;

// Control block layout (immortal):
//   [0] ARENA_MAGIC
//   [1] current_chunk
//   [2] first_chunk
//   [3] last_chunk_cap   (data slots in newest chunk — for 1.5× growth)
//   [4] alive
//   [5] byte_current
//   [6] byte_first
//
// Value chunk layout (immortal):
//   [0] CHUNK_MAGIC
//   [1] data_base
//   [2] data_end
//   [3] watermark
//   [4] next_chunk       (0 = none)
//   [5 ..] data
//
// Byte chunk header (immortal Value slots; payload in vm.bytes):
//   [0] BYTE_CHUNK_MAGIC
//   [1] bytes_offset
//   [2] cap
//   [3] watermark
//   [4] next

var alloc_native: NativeFunction = undefined;
var alloc_immortal_native: NativeFunction = undefined;
var alloc_bytes_native: NativeFunction = undefined;
var alloc_immortal_bytes_native: NativeFunction = undefined;
var arena_create_native: NativeFunction = undefined;
var arena_alloc_native: NativeFunction = undefined;
var arena_alloc_array_native: NativeFunction = undefined;
var arena_reset_native: NativeFunction = undefined;
var arena_deinit_native: NativeFunction = undefined;
var arena_alloc_bytes_native: NativeFunction = undefined;

fn fail(vm: *VMState, comptime op: []const u8, comptime msg: []const u8) error{RuntimeError} {
    return runtime.runtimeFail(vm, op ++ ": " ++ msg);
}

fn asHeapPtr(v: Value) !i32 {
    return switch (v) {
        .ptr => |p| p,
        .int => |n| @intCast(n),
        else => error.TypeError,
    };
}

/// Resolve Arena object or raw control handle → control block base.
fn resolveArenaControl(vm: *VMState, v: Value) !i32 {
    // Packed `Arena { handle: int }` (8 bytes in vm.bytes).
    if (v == .bytes) {
        const b = v.bytes;
        if (b.len < 8) return error.TypeError;
        const ctrl: i32 = @intCast(std.mem.readInt(i64, vm.bytes.items[b.offset..][0..8], .little));
        if (!vm.isValidHeapPtr(ctrl)) return error.TypeError;
        if (vm.slot(ctrl).* == .int and vm.slot(ctrl).*.int == ARENA_MAGIC)
            return ctrl;
        return error.TypeError;
    }
    const raw = try asHeapPtr(v);
    if (!vm.isValidHeapPtr(raw)) return error.TypeError;
    if (vm.slot(raw).* == .int and vm.slot(raw).*.int == ARENA_MAGIC)
        return raw;
    // Legacy Value-slot Arena object: slot 0 = control ptr.
    const slot = vm.slot(raw).*;
    const candidate = try asHeapPtr(slot);
    if (!vm.isValidHeapPtr(candidate)) return error.TypeError;
    if (vm.slot(candidate).* == .int and vm.slot(candidate).*.int == ARENA_MAGIC)
        return candidate;
    return error.TypeError;
}

fn arenaAlive(vm: *VMState, ctrl: i32, comptime op: []const u8) !void {
    if (vm.slot(ctrl + 4).*.int != 1)
        return fail(vm, op, "arena is deinitialized");
}

fn makeChunk(vm: *VMState, cap: i32) !i32 {
    // 1. Search free list for a chunk >= cap
    var prev: i32 = 0;
    var curr = vm.free_chunks;
    while (curr != 0) {
        const c_data_base: i32 = @intCast(vm.slot(curr + 1).*.int);
        const c_data_end: i32 = @intCast(vm.slot(curr + 2).*.int);
        const c_cap = c_data_end - c_data_base;
        if (c_cap >= cap) {
            // Unlink from free list
            const next = vm.slot(curr + 4).*.int;
            if (prev == 0) {
                vm.free_chunks = @intCast(next);
            } else {
                vm.slot(prev + 4).* = .{ .int = next };
            }
            // Re-initialize chunk
            vm.slot(curr).* = .{ .int = CHUNK_MAGIC };
            vm.slot(curr + 1).* = .{ .int = curr + 5 };
            vm.slot(curr + 2).* = .{ .int = curr + 5 + c_cap };
            vm.slot(curr + 3).* = .{ .int = curr + 5 };
            vm.slot(curr + 4).* = .{ .int = 0 }; // next
            return curr;
        }
        prev = curr;
        curr = @intCast(vm.slot(curr + 4).*.int);
    }

    // 2. Fallback to fresh allocation
    const chunk = try vm.allocImmortal(5 + cap);
    vm.slot(chunk).* = .{ .int = CHUNK_MAGIC };
    vm.slot(chunk + 1).* = .{ .int = chunk + 5 };
    vm.slot(chunk + 2).* = .{ .int = chunk + 5 + cap };
    vm.slot(chunk + 3).* = .{ .int = chunk + 5 };
    vm.slot(chunk + 4).* = .{ .int = 0 }; // next
    return chunk;
}

fn makeByteChunk(vm: *VMState, cap: i32) !i32 {
    var prev: i32 = 0;
    var curr = vm.free_byte_chunks;
    while (curr != 0) {
        const c_cap: i32 = @intCast(vm.slot(curr + 2).*.int);
        if (c_cap >= cap) {
            const next = vm.slot(curr + 4).*.int;
            if (prev == 0) {
                vm.free_byte_chunks = @intCast(next);
            } else {
                vm.slot(prev + 4).* = .{ .int = next };
            }
            const off: i32 = @intCast(vm.slot(curr + 1).*.int);
            @memset(vm.bytes.items[@intCast(off)..][0..@intCast(c_cap)], 0);
            vm.slot(curr).* = .{ .int = BYTE_CHUNK_MAGIC };
            vm.slot(curr + 3).* = .{ .int = 0 };
            vm.slot(curr + 4).* = .{ .int = 0 };
            return curr;
        }
        prev = curr;
        curr = @intCast(vm.slot(curr + 4).*.int);
    }

    const off = try vm.allocImmortalBytes(cap);
    const hdr = try vm.allocImmortal(5);
    vm.slot(hdr).* = .{ .int = BYTE_CHUNK_MAGIC };
    vm.slot(hdr + 1).* = .{ .int = off };
    vm.slot(hdr + 2).* = .{ .int = cap };
    vm.slot(hdr + 3).* = .{ .int = 0 };
    vm.slot(hdr + 4).* = .{ .int = 0 };
    return hdr;
}

fn bumpInByteChunk(vm: *VMState, chunk: i32, n: i32) ?i32 {
    if (vm.slot(chunk).*.int != BYTE_CHUNK_MAGIC) return null;
    const watermark = vm.slot(chunk + 3).*.int;
    const cap = vm.slot(chunk + 2).*.int;
    if (watermark + n > cap) return null;
    vm.slot(chunk + 3).* = .{ .int = watermark + n };
    const off = vm.slot(chunk + 1).*.int;
    return @intCast(off + watermark);
}

fn allocFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const n = switch (args[0]) {
        .int => |x| x,
        else => return error.TypeError,
    };
    const ptr = try vm.allocSlots(@intCast(n));
    return .{ .ptr = ptr };
}

fn allocImmortalFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const n = switch (args[0]) {
        .int => |x| x,
        else => return error.TypeError,
    };
    const ptr = try vm.allocImmortal(@intCast(n));
    return .{ .ptr = ptr };
}

fn allocBytesFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const n = switch (args[0]) {
        .int => |x| x,
        else => return error.TypeError,
    };
    if (n < 0) return error.TypeError;
    if (n == 0) return .{ .bytes = .{ .offset = 0, .len = 0 } };
    const off = try vm.allocFrameBytes(@intCast(n));
    return .{ .bytes = .{ .offset = @intCast(off), .len = @intCast(n) } };
}

fn allocImmortalBytesFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const n = switch (args[0]) {
        .int => |x| x,
        else => return error.TypeError,
    };
    if (n < 0) return error.TypeError;
    if (n == 0) return .{ .bytes = .{ .offset = 0, .len = 0 } };
    const off = try vm.allocImmortalBytes(@intCast(n));
    return .{ .bytes = .{ .offset = @intCast(off), .len = @intCast(n) } };
}

fn arenaCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const hint = switch (args[0]) {
        .int => |x| x,
        else => return fail(vm, "__arena_create", "invalid capacity"),
    };
    if (hint < 0) return fail(vm, "__arena_create", "invalid capacity");
    // hint = initial chunk size (0 → DEFAULT_CHUNK). Arena grows when full (Zig-like).
    const cap: i32 = if (hint == 0) DEFAULT_CHUNK else @intCast(hint);

    const chunk = try makeChunk(vm, cap);
    const byte_chunk = try makeByteChunk(vm, cap);
    const ctrl = try vm.allocImmortal(7);
    vm.slot(ctrl).* = .{ .int = ARENA_MAGIC };
    vm.slot(ctrl + 1).* = .{ .ptr = chunk }; // current
    vm.slot(ctrl + 2).* = .{ .ptr = chunk }; // first
    vm.slot(ctrl + 3).* = .{ .int = cap };
    vm.slot(ctrl + 4).* = .{ .int = 1 }; // alive
    vm.slot(ctrl + 5).* = .{ .ptr = byte_chunk };
    vm.slot(ctrl + 6).* = .{ .ptr = byte_chunk };

    // Packed `Arena { handle: int }` — 8-byte object in the byte heap.
    const off = try vm.allocImmortalBytes(8);
    std.mem.writeInt(i64, vm.bytes.items[@intCast(off)..][0..8], ctrl, .little);
    return .{ .bytes = .{ .offset = @intCast(off), .len = 8 } };
}

fn bumpInChunk(vm: *VMState, chunk: i32, n: i32) ?i32 {
    if (vm.slot(chunk).*.int != CHUNK_MAGIC) return null;
    const watermark = vm.slot(chunk + 3).*.int;
    const data_end = vm.slot(chunk + 2).*.int;
    if (watermark + n > data_end) return null;
    vm.slot(chunk + 3).* = .{ .int = watermark + n };
    return @intCast(watermark);
}

fn arenaAlloc(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const ctrl = try resolveArenaControl(vm, args[0]);
    const n = switch (args[1]) {
        .int => |x| x,
        else => return fail(vm, "__arena_alloc", "invalid size"),
    };
    if (n < 0) return fail(vm, "__arena_alloc", "invalid size");
    try arenaAlive(vm, ctrl, "__arena_alloc");

    const cur_val = vm.slot(ctrl + 1).*;
    const cur = try asHeapPtr(cur_val);
    if (bumpInChunk(vm, cur, @intCast(n))) |ptr| return .{ .ptr = ptr };

    // Grow: new chunk ≥ max(n, 1.5× last cap), like Zig ArenaAllocator.
    const last_cap = vm.slot(ctrl + 3).*.int;
    const grown = last_cap + @divTrunc(last_cap, 2);
    const new_cap = @max(n, @max(grown, DEFAULT_CHUNK));
    const new_chunk = try makeChunk(vm, @intCast(new_cap));

    // Append to list (from current).
    vm.slot(cur + 4).* = .{ .ptr = new_chunk };
    vm.slot(ctrl + 1).* = .{ .ptr = new_chunk };
    vm.slot(ctrl + 3).* = .{ .int = new_cap };

    const ptr = bumpInChunk(vm, new_chunk, @intCast(n)) orelse return error.OutOfMemory;
    return .{ .ptr = ptr };
}

/// Length-prefixed zeroed array: slots = len+1, returns data pointer (length at ptr-1).
fn arenaAllocArray(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const len = switch (args[1]) {
        .int => |x| x,
        else => return fail(vm, "__arena_alloc_array", "invalid length"),
    };
    if (len < 0) return fail(vm, "__arena_alloc_array", "invalid length");
    var alloc_args = [_]Value{ args[0], .{ .int = len + 1 } };
    const base_v = try arenaAlloc(vm_ptr, &alloc_args);
    const base = switch (base_v) {
        .ptr => |p| p,
        else => return fail(vm, "__arena_alloc_array", "invalid allocation"),
    };
    vm.slot(base).* = .{ .int = len };
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        vm.slot(base + i).* = .{ .int = 0 };
    }
    return .{ .ptr = base + 1 };
}

/// Packed `n` bytes (one byte per element). Returns `.bytes`.
fn arenaAllocBytes(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const ctrl = try resolveArenaControl(vm, args[0]);
    const n = switch (args[1]) {
        .int => |x| x,
        else => return fail(vm, "__arena_alloc_bytes", "invalid size"),
    };
    if (n < 0) return fail(vm, "__arena_alloc_bytes", "invalid size");
    try arenaAlive(vm, ctrl, "__arena_alloc_bytes");
    if (n == 0) return .{ .bytes = .{ .offset = 0, .len = 0 } };

    const cur_val = vm.slot(ctrl + 5).*;
    const cur = try asHeapPtr(cur_val);
    if (bumpInByteChunk(vm, cur, @intCast(n))) |off| {
        @memset(vm.bytes.items[@intCast(off)..][0..@intCast(n)], 0);
        return .{ .bytes = .{ .offset = @intCast(off), .len = @intCast(n) } };
    }

    const last_cap = vm.slot(cur + 2).*.int;
    const grown = last_cap + @divTrunc(last_cap, 2);
    const new_cap = @max(n, @max(grown, DEFAULT_CHUNK));
    const new_chunk = try makeByteChunk(vm, @intCast(new_cap));

    vm.slot(cur + 4).* = .{ .ptr = new_chunk };
    vm.slot(ctrl + 5).* = .{ .ptr = new_chunk };

    const off = bumpInByteChunk(vm, new_chunk, @intCast(n)) orelse return error.OutOfMemory;
    @memset(vm.bytes.items[@intCast(off)..][0..@intCast(n)], 0);
    return .{ .bytes = .{ .offset = @intCast(off), .len = @intCast(n) } };
}

fn arenaReset(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const ctrl = try resolveArenaControl(vm, args[0]);
    try arenaAlive(vm, ctrl, "__arena_reset");

    // Retain capacity: rewind every chunk watermark, resume at first (Zig .retain_capacity).
    var chunk_v = vm.slot(ctrl + 2).*;
    while (true) {
        const chunk = try asHeapPtr(chunk_v);
        if (chunk == 0) break;
        if (vm.slot(chunk).*.int != CHUNK_MAGIC) break;
        vm.slot(chunk + 3).* = vm.slot(chunk + 1).*; // watermark = data_base
        const next = vm.slot(chunk + 4).*;
        chunk_v = next;
        const next_p = asHeapPtr(next) catch break;
        if (next_p == 0) break;
    }
    vm.slot(ctrl + 1).* = vm.slot(ctrl + 2).*; // current = first

    var bchunk_v = vm.slot(ctrl + 6).*;
    while (true) {
        const bchunk = try asHeapPtr(bchunk_v);
        if (bchunk == 0) break;
        if (vm.slot(bchunk).*.int != BYTE_CHUNK_MAGIC) break;
        vm.slot(bchunk + 3).* = .{ .int = 0 };
        const next = vm.slot(bchunk + 4).*;
        bchunk_v = next;
        const next_p = asHeapPtr(next) catch break;
        if (next_p == 0) break;
    }
    vm.slot(ctrl + 5).* = vm.slot(ctrl + 6).*;
    return .null;
}

fn arenaDeinit(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const ctrl = try resolveArenaControl(vm, args[0]);
    if (vm.slot(ctrl).*.int != ARENA_MAGIC)
        return fail(vm, "__arena_deinit", "invalid arena");
        
    // Walk the chunks and push them to vm.free_chunks
    var chunk_v = vm.slot(ctrl + 2).*; // first chunk
    while (true) {
        const chunk = try asHeapPtr(chunk_v);
        if (chunk == 0) break;
        if (vm.slot(chunk).*.int != CHUNK_MAGIC) break;
        
        const next = vm.slot(chunk + 4).*;
        
        // Push this chunk to the free list
        vm.slot(chunk + 4).* = .{ .int = vm.free_chunks };
        vm.free_chunks = chunk;
        
        chunk_v = next;
    }

    var bchunk_v = vm.slot(ctrl + 6).*;
    while (true) {
        const bchunk = try asHeapPtr(bchunk_v);
        if (bchunk == 0) break;
        if (vm.slot(bchunk).*.int != BYTE_CHUNK_MAGIC) break;
        const next = vm.slot(bchunk + 4).*;
        vm.slot(bchunk + 4).* = .{ .int = vm.free_byte_chunks };
        vm.free_byte_chunks = bchunk;
        bchunk_v = next;
    }

    vm.slot(ctrl + 4).* = .{ .int = 0 }; // Mark arena as dead
    return .null;
}

pub fn register(vm: *VMState) !void {
    alloc_native = .{ .name = "__alloc", .func = allocFn, .arity = 1 };
    alloc_immortal_native = .{ .name = "__allocImmortal", .func = allocImmortalFn, .arity = 1 };
    alloc_bytes_native = .{ .name = "__allocBytes", .func = allocBytesFn, .arity = 1 };
    alloc_immortal_bytes_native = .{ .name = "__allocImmortalBytes", .func = allocImmortalBytesFn, .arity = 1 };
    arena_create_native = .{ .name = "__arena_create", .func = arenaCreate, .arity = 1 };
    arena_alloc_native = .{ .name = "__arena_alloc", .func = arenaAlloc, .arity = 2 };
    arena_alloc_array_native = .{ .name = "__arena_alloc_array", .func = arenaAllocArray, .arity = 2 };
    arena_reset_native = .{ .name = "__arena_reset", .func = arenaReset, .arity = 1 };
    arena_deinit_native = .{ .name = "__arena_deinit", .func = arenaDeinit, .arity = 1 };
    arena_alloc_bytes_native = .{ .name = "__arena_alloc_bytes", .func = arenaAllocBytes, .arity = 2 };

    try vm.defineGlobal("__alloc", .{ .native = &alloc_native });
    try vm.defineGlobal("__allocImmortal", .{ .native = &alloc_immortal_native });
    try vm.defineGlobal("__allocBytes", .{ .native = &alloc_bytes_native });
    try vm.defineGlobal("__allocImmortalBytes", .{ .native = &alloc_immortal_bytes_native });
    try vm.defineGlobal("__arena_create", .{ .native = &arena_create_native });
    try vm.defineGlobal("__arena_alloc", .{ .native = &arena_alloc_native });
    try vm.defineGlobal("__arena_alloc_array", .{ .native = &arena_alloc_array_native });
    try vm.defineGlobal("__arena_alloc_bytes", .{ .native = &arena_alloc_bytes_native });
    try vm.defineGlobal("__arena_reset", .{ .native = &arena_reset_native });
    try vm.defineGlobal("__arena_deinit", .{ .native = &arena_deinit_native });
}
