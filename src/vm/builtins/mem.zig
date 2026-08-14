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

/// Default first-chunk data slots when create(0) / tiny hint.
const DEFAULT_CHUNK: i32 = 64;

// Control block layout (immortal):
//   [0] ARENA_MAGIC
//   [1] current_chunk
//   [2] first_chunk
//   [3] last_chunk_cap   (data slots in newest chunk — for 1.5× growth)
//   [4] alive
//
// Chunk layout (immortal):
//   [0] CHUNK_MAGIC
//   [1] data_base
//   [2] data_end
//   [3] watermark
//   [4] next_chunk       (0 = none)
//   [5 ..] data

var alloc_native: NativeFunction = undefined;
var alloc_immortal_native: NativeFunction = undefined;
var arena_create_native: NativeFunction = undefined;
var arena_alloc_native: NativeFunction = undefined;
var arena_alloc_array_native: NativeFunction = undefined;
var arena_reset_native: NativeFunction = undefined;
var arena_deinit_native: NativeFunction = undefined;

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
    const raw = try asHeapPtr(v);
    if (!vm.isValidHeapPtr(raw)) return error.TypeError;
    if (vm.memory[@intCast(raw)] == .int and vm.memory[@intCast(raw)].int == ARENA_MAGIC)
        return raw;
    // Arena struct object: slot 0 = control ptr.
    const slot = vm.memory[@intCast(raw)];
    const candidate = try asHeapPtr(slot);
    if (!vm.isValidHeapPtr(candidate)) return error.TypeError;
    if (vm.memory[@intCast(candidate)] == .int and vm.memory[@intCast(candidate)].int == ARENA_MAGIC)
        return candidate;
    return error.TypeError;
}

fn arenaAlive(vm: *VMState, ctrl: i32, comptime op: []const u8) !void {
    if (vm.memory[@intCast(ctrl + 4)].int != 1)
        return fail(vm, op, "arena is deinitialized");
}

fn makeChunk(vm: *VMState, cap: i32) !i32 {
    const chunk = try vm.allocImmortal(5 + cap);
    vm.memory[@intCast(chunk)] = .{ .int = CHUNK_MAGIC };
    vm.memory[@intCast(chunk + 1)] = .{ .int = chunk + 5 };
    vm.memory[@intCast(chunk + 2)] = .{ .int = chunk + 5 + cap };
    vm.memory[@intCast(chunk + 3)] = .{ .int = chunk + 5 };
    vm.memory[@intCast(chunk + 4)] = .{ .int = 0 }; // next
    return chunk;
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
    const ctrl = try vm.allocImmortal(5);
    vm.memory[@intCast(ctrl)] = .{ .int = ARENA_MAGIC };
    vm.memory[@intCast(ctrl + 1)] = .{ .ptr = chunk }; // current
    vm.memory[@intCast(ctrl + 2)] = .{ .ptr = chunk }; // first
    vm.memory[@intCast(ctrl + 3)] = .{ .int = cap };
    vm.memory[@intCast(ctrl + 4)] = .{ .int = 1 }; // alive

    const obj = try vm.allocImmortal(1);
    vm.memory[@intCast(obj)] = .{ .ptr = ctrl };
    return .{ .ptr = obj };
}

fn bumpInChunk(vm: *VMState, chunk: i32, n: i32) ?i32 {
    if (vm.memory[@intCast(chunk)].int != CHUNK_MAGIC) return null;
    const watermark = vm.memory[@intCast(chunk + 3)].int;
    const data_end = vm.memory[@intCast(chunk + 2)].int;
    if (watermark + n > data_end) return null;
    vm.memory[@intCast(chunk + 3)] = .{ .int = watermark + n };
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

    const cur_val = vm.memory[@intCast(ctrl + 1)];
    const cur = try asHeapPtr(cur_val);
    if (bumpInChunk(vm, cur, @intCast(n))) |ptr| return .{ .ptr = ptr };

    // Grow: new chunk ≥ max(n, 1.5× last cap), like Zig ArenaAllocator.
    const last_cap = vm.memory[@intCast(ctrl + 3)].int;
    const grown = last_cap + @divTrunc(last_cap, 2);
    const new_cap = @max(n, @max(grown, DEFAULT_CHUNK));
    const new_chunk = try makeChunk(vm, @intCast(new_cap));

    // Append to list (from current).
    vm.memory[@intCast(cur + 4)] = .{ .ptr = new_chunk };
    vm.memory[@intCast(ctrl + 1)] = .{ .ptr = new_chunk };
    vm.memory[@intCast(ctrl + 3)] = .{ .int = new_cap };

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
    vm.memory[@intCast(base)] = .{ .int = len };
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        vm.memory[@intCast(base + i)] = .{ .int = 0 };
    }
    return .{ .ptr = base + 1 };
}

fn arenaReset(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const ctrl = try resolveArenaControl(vm, args[0]);
    try arenaAlive(vm, ctrl, "__arena_reset");

    // Retain capacity: rewind every chunk watermark, resume at first (Zig .retain_capacity).
    var chunk_v = vm.memory[@intCast(ctrl + 2)];
    while (true) {
        const chunk = try asHeapPtr(chunk_v);
        if (chunk == 0) break;
        if (vm.memory[@intCast(chunk)].int != CHUNK_MAGIC) break;
        vm.memory[@intCast(chunk + 3)] = vm.memory[@intCast(chunk + 1)]; // watermark = data_base
        const next = vm.memory[@intCast(chunk + 4)];
        chunk_v = next;
        const next_p = asHeapPtr(next) catch break;
        if (next_p == 0) break;
    }
    vm.memory[@intCast(ctrl + 1)] = vm.memory[@intCast(ctrl + 2)]; // current = first
    return .null;
}

fn arenaDeinit(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const ctrl = try resolveArenaControl(vm, args[0]);
    if (vm.memory[@intCast(ctrl)].int != ARENA_MAGIC)
        return fail(vm, "__arena_deinit", "invalid arena");
    vm.memory[@intCast(ctrl + 4)] = .{ .int = 0 };
    return .null;
}

pub fn register(vm: *VMState) !void {
    alloc_native = .{ .name = "__alloc", .func = allocFn, .arity = 1 };
    alloc_immortal_native = .{ .name = "__allocImmortal", .func = allocImmortalFn, .arity = 1 };
    arena_create_native = .{ .name = "__arena_create", .func = arenaCreate, .arity = 1 };
    arena_alloc_native = .{ .name = "__arena_alloc", .func = arenaAlloc, .arity = 2 };
    arena_alloc_array_native = .{ .name = "__arena_alloc_array", .func = arenaAllocArray, .arity = 2 };
    arena_reset_native = .{ .name = "__arena_reset", .func = arenaReset, .arity = 1 };
    arena_deinit_native = .{ .name = "__arena_deinit", .func = arenaDeinit, .arity = 1 };

    try vm.globals.put("__alloc", .{ .native = &alloc_native });
    try vm.globals.put("__allocImmortal", .{ .native = &alloc_immortal_native });
    try vm.globals.put("__arena_create", .{ .native = &arena_create_native });
    try vm.globals.put("__arena_alloc", .{ .native = &arena_alloc_native });
    try vm.globals.put("__arena_alloc_array", .{ .native = &arena_alloc_array_native });
    try vm.globals.put("__arena_reset", .{ .native = &arena_reset_native });
    try vm.globals.put("__arena_deinit", .{ .native = &arena_deinit_native });
}
