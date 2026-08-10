const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;
const ARENA_MAGIC: i32 = 0xa5ea;

var alloc_native: NativeFunction = undefined;
var arena_create_native: NativeFunction = undefined;
var arena_alloc_native: NativeFunction = undefined;
var arena_reset_native: NativeFunction = undefined;
var arena_deinit_native: NativeFunction = undefined;

fn fail(comptime op: []const u8, comptime msg: []const u8) error{TypeError} {
    std.debug.print("RuntimeError: {s}: {s}\n", .{ op, msg });
    return error.TypeError;
}

/// Accept either a raw slab handle or an Arena object `{ handle }` from std.mem.
fn resolveArenaSlab(vm: *VMState, v: Value) !i32 {
    const raw: i32 = switch (v) {
        .ptr => |p| p,
        .int => |n| n,
        else => return error.TypeError,
    };
    if (raw < 0 or raw >= vm.heap_ptr) return error.TypeError;
    // Already the slab header.
    if (vm.memory[@intCast(raw)] == .int and vm.memory[@intCast(raw)].int == ARENA_MAGIC)
        return raw;
    // Arena object: slot 0 holds slab ptr/int.
    const slot = vm.memory[@intCast(raw)];
    const candidate: i32 = switch (slot) {
        .ptr => |p| p,
        .int => |n| n,
        else => return error.TypeError,
    };
    if (candidate < 0 or candidate >= vm.heap_ptr) return error.TypeError;
    if (vm.memory[@intCast(candidate)] == .int and vm.memory[@intCast(candidate)].int == ARENA_MAGIC)
        return candidate;
    return error.TypeError;
}

fn arenaCheck(vm: *VMState, arena: i32, comptime op: []const u8) !void {
    if (arena < 0 or arena >= vm.heap_ptr or vm.memory[@intCast(arena)].int != ARENA_MAGIC)
        return error.TypeError;
    if (vm.memory[@intCast(arena + 4)].int != 1)
        return fail(op, "arena is deinitialized");
}

fn allocFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const n = switch (args[0]) {
        .int => |x| x,
        else => return error.TypeError,
    };
    // Frame-local bump (rewound on return unless escape analysis forbids returning it).
    const ptr = try vm.allocSlots(n);
    return .{ .ptr = ptr };
}

fn arenaCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const cap = switch (args[0]) {
        .int => |x| x,
        else => return fail("__arena_create", "invalid capacity"),
    };
    if (cap < 0) return fail("__arena_create", "invalid capacity");
    // Immortal: std.mem.create returns this across frames; must not be rewound.
    // Layout: slab [magic, base, end, watermark, alive, …cap] + Arena object [handle].
    const slab = try vm.allocImmortal(5 + cap);
    vm.memory[@intCast(slab)] = .{ .int = ARENA_MAGIC };
    vm.memory[@intCast(slab + 1)] = .{ .int = slab + 5 };
    vm.memory[@intCast(slab + 2)] = .{ .int = slab + 5 + cap };
    vm.memory[@intCast(slab + 3)] = .{ .int = slab + 5 };
    vm.memory[@intCast(slab + 4)] = .{ .int = 1 };
    const obj = try vm.allocImmortal(1);
    vm.memory[@intCast(obj)] = .{ .ptr = slab };
    return .{ .ptr = obj };
}

fn arenaAlloc(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const arena = try resolveArenaSlab(vm, args[0]);
    const n = switch (args[1]) {
        .int => |x| x,
        else => return fail("__arena_alloc", "invalid size"),
    };
    if (n < 0) return fail("__arena_alloc", "invalid size");
    try arenaCheck(vm, arena, "__arena_alloc");
    const watermark = vm.memory[@intCast(arena + 3)].int;
    const data_end = vm.memory[@intCast(arena + 2)].int;
    if (watermark + n > data_end) {
        std.debug.print("RuntimeError: __arena_alloc: out of capacity\n", .{});
        return error.OutOfMemory;
    }
    vm.memory[@intCast(arena + 3)] = .{ .int = watermark + n };
    return .{ .ptr = watermark };
}

fn arenaReset(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const arena = try resolveArenaSlab(vm, args[0]);
    try arenaCheck(vm, arena, "__arena_reset");
    vm.memory[@intCast(arena + 3)] = vm.memory[@intCast(arena + 1)];
    return .null;
}

fn arenaDeinit(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const arena = try resolveArenaSlab(vm, args[0]);
    if (arena < 0 or arena >= vm.heap_ptr or vm.memory[@intCast(arena)].int != ARENA_MAGIC)
        return fail("__arena_deinit", "invalid arena");
    vm.memory[@intCast(arena + 4)] = .{ .int = 0 };
    return .null;
}

pub fn register(vm: *VMState) !void {
    alloc_native = .{ .name = "__alloc", .func = allocFn, .arity = 1 };
    arena_create_native = .{ .name = "__arena_create", .func = arenaCreate, .arity = 1 };
    arena_alloc_native = .{ .name = "__arena_alloc", .func = arenaAlloc, .arity = 2 };
    arena_reset_native = .{ .name = "__arena_reset", .func = arenaReset, .arity = 1 };
    arena_deinit_native = .{ .name = "__arena_deinit", .func = arenaDeinit, .arity = 1 };

    try vm.globals.put("__alloc", .{ .native = &alloc_native });
    try vm.globals.put("__arena_create", .{ .native = &arena_create_native });
    try vm.globals.put("__arena_alloc", .{ .native = &arena_alloc_native });
    try vm.globals.put("__arena_reset", .{ .native = &arena_reset_native });
    try vm.globals.put("__arena_deinit", .{ .native = &arena_deinit_native });
}
