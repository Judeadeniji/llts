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

fn arenaHandle(v: Value) !i32 {
    return switch (v) {
        .ptr => |p| p,
        .int => |n| n,
        else => error.TypeError,
    };
}

fn arenaCheck(vm: *VMState, arena: i32, comptime op: []const u8) !void {
    if (arena < 0 or arena >= vm.heap_ptr or vm.memory[@intCast(arena)] != ARENA_MAGIC)
        return fail(op, "invalid arena");
    if (vm.memory[@intCast(arena + 4)] != 1)
        return fail(op, "arena is deinitialized");
}

fn allocFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const n = switch (args[0]) {
        .int => |x| x,
        else => return error.TypeError,
    };
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
    const base = try vm.allocSlots(5 + cap);
    vm.memory[@intCast(base)] = ARENA_MAGIC;
    vm.memory[@intCast(base + 1)] = base + 5; // data_base
    vm.memory[@intCast(base + 2)] = base + 5 + cap; // data_end
    vm.memory[@intCast(base + 3)] = base + 5; // watermark
    vm.memory[@intCast(base + 4)] = 1; // alive
    return .{ .ptr = base };
}

fn arenaAlloc(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const arena = try arenaHandle(args[0]);
    const n = switch (args[1]) {
        .int => |x| x,
        else => return fail("__arena_alloc", "invalid size"),
    };
    if (n < 0) return fail("__arena_alloc", "invalid size");
    try arenaCheck(vm, arena, "__arena_alloc");
    const watermark = vm.memory[@intCast(arena + 3)];
    const data_end = vm.memory[@intCast(arena + 2)];
    if (watermark + n > data_end) return fail("__arena_alloc", "out of capacity");
    vm.memory[@intCast(arena + 3)] = watermark + n;
    return .{ .ptr = watermark };
}

fn arenaReset(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const arena = try arenaHandle(args[0]);
    try arenaCheck(vm, arena, "__arena_reset");
    vm.memory[@intCast(arena + 3)] = vm.memory[@intCast(arena + 1)];
    return .null;
}

fn arenaDeinit(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const arena = try arenaHandle(args[0]);
    if (arena < 0 or arena >= vm.heap_ptr or vm.memory[@intCast(arena)] != ARENA_MAGIC)
        return fail("__arena_deinit", "invalid arena");
    vm.memory[@intCast(arena + 4)] = 0;
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
