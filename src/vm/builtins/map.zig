const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");
const mem = @import("mem.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var map_create_n: NativeFunction = undefined;
var map_set_n: NativeFunction = undefined;
var map_get_n: NativeFunction = undefined;
var map_has_n: NativeFunction = undefined;
var map_delete_n: NativeFunction = undefined;
var map_size_n: NativeFunction = undefined;

fn arenaVal(ctrl: i32) Value {
    return .{ .ptr = ctrl };
}

fn keyEquals(vm: *VMState, stored: Value, key: []const u8) bool {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const s = util.valueToStr(vm, stored, &buf) catch return false;
    return std.mem.eql(u8, s, key);
}

fn findKey(vm: *VMState, mp: *value.MapObject, key: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < mp.keys.count) : (i += 1) {
        if (keyEquals(vm, vm.arrayElemConst(mp.keys, i), key)) return i;
    }
    return null;
}

fn internKey(vm: *VMState, arena: Value, key: []const u8) !Value {
    // Copy key bytes into arena and return a slice Value.
    const bref = try mem.allocBytesInArena(vm, arena, @intCast(key.len), @intCast(key.len));
    if (key.len > 0) {
        @memcpy(vm.bytes.items[bref.offset..][0..key.len], key);
    }
    return .{ .slice = .{ .offset = bref.offset, .len = bref.len } };
}

fn mapCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const ctrl = try mem.resolveArena(vm, args[0]);
    try mem.requireArenaAlive(vm, ctrl, "__mapCreate");
    const mp = try vm.allocMap();
    mp.arena_ctrl = ctrl;
    mp.arena_gen = mem.arenaGeneration(vm, ctrl);
    mp.keys = try mem.allocArrayInArena(vm, args[0], 0, 8);
    mp.values = try mem.allocArrayInArena(vm, args[0], 0, 8);
    return .{ .map = mp };
}

fn mapSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .map) return error.TypeError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);

    const mp = args[0].map;
    try mem.requireContainerArena(vm, mp.arena_ctrl, mp.arena_gen, "__mapSet");
    if (mp.arena_ctrl == 0) return error.TypeError; // maps require an arena today
    const arena = arenaVal(mp.arena_ctrl);

    if (findKey(vm, mp, key)) |idx| {
        vm.arrayElemPtr(mp.values, idx).* = args[2];
        return args[2];
    }

    const key_v = try internKey(vm, arena, key);
    mp.keys = try mem.pushArray(vm, arena, mp.arena_ctrl, mp.keys, key_v);
    mp.values = try mem.pushArray(vm, arena, mp.arena_ctrl, mp.values, args[2]);
    return args[2];
}

fn mapGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);

    const mp = args[0].map;
    try mem.requireContainerArena(vm, mp.arena_ctrl, mp.arena_gen, "__mapGet");
    if (findKey(vm, mp, key)) |idx| {
        return vm.arrayElemConst(mp.values, idx);
    }
    return .null;
}

fn mapHas(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);

    const mp = args[0].map;
    try mem.requireContainerArena(vm, mp.arena_ctrl, mp.arena_gen, "__mapHas");
    return Value.fromBool(findKey(vm, mp, key) != null);
}

fn mapDelete(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);

    const mp = args[0].map;
    try mem.requireContainerArena(vm, mp.arena_ctrl, mp.arena_gen, "__mapDelete");
    const idx = findKey(vm, mp, key) orelse return Value.fromBool(false);
    // Swap-remove
    const last = mp.keys.count - 1;
    if (idx != last) {
        vm.arrayElemPtr(mp.keys, idx).* = vm.arrayElemConst(mp.keys, last);
        vm.arrayElemPtr(mp.values, idx).* = vm.arrayElemConst(mp.values, last);
    }
    mp.keys.count = last;
    mp.values.count = last;
    return Value.fromBool(true);
}

fn mapSize(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    const mp = args[0].map;
    try mem.requireContainerArena(vm, mp.arena_ctrl, mp.arena_gen, "__mapSize");
    return .{ .i64 = @intCast(mp.keys.count) };
}

pub fn register(vm: *VMState) !void {
    map_create_n = .{ .name = "__mapCreate", .func = mapCreate, .arity = 1 };
    map_set_n = .{ .name = "__mapSet", .func = mapSet, .arity = 3 };
    map_get_n = .{ .name = "__mapGet", .func = mapGet, .arity = 2 };
    map_has_n = .{ .name = "__mapHas", .func = mapHas, .arity = 2 };
    map_delete_n = .{ .name = "__mapDelete", .func = mapDelete, .arity = 2 };
    map_size_n = .{ .name = "__mapSize", .func = mapSize, .arity = 1 };

    try vm.defineGlobal("__mapCreate", .{ .native = &map_create_n });
    try vm.defineGlobal("__mapSet", .{ .native = &map_set_n });
    try vm.defineGlobal("__mapGet", .{ .native = &map_get_n });
    try vm.defineGlobal("__mapHas", .{ .native = &map_has_n });
    try vm.defineGlobal("__mapDelete", .{ .native = &map_delete_n });
    try vm.defineGlobal("__mapSize", .{ .native = &map_size_n });
}
