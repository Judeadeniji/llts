const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const mem = @import("mem.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var list_create_n: NativeFunction = undefined;
var list_create_immortal_n: NativeFunction = undefined;
var list_push_n: NativeFunction = undefined;
var list_pop_n: NativeFunction = undefined;
var list_get_n: NativeFunction = undefined;
var list_set_n: NativeFunction = undefined;
var list_len_n: NativeFunction = undefined;

fn arenaOpt(ctrl: i32) ?Value {
    if (ctrl == 0) return null;
    return .{ .ptr = ctrl };
}

fn listCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const ctrl = try mem.resolveArena(vm, args[0]);
    try mem.requireArenaAlive(vm, ctrl, "__listCreate");
    const lst = try vm.allocList();
    lst.arena_ctrl = ctrl;
    lst.arena_gen = mem.arenaGeneration(vm, ctrl);
    lst.items = try mem.allocArrayInArena(vm, args[0], 0, 8);
    return .{ .list = lst };
}

/// Process-lifetime list (not reclaimed by any arena). Prefer `create(arena)`.
fn listCreateImmortal(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const lst = try vm.allocList();
    lst.arena_ctrl = 0;
    lst.arena_gen = 0;
    lst.items = try mem.allocArrayImmortal(vm, 0, 8);
    return .{ .list = lst };
}

fn listPush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .list) return error.TypeError;
    const lst = args[0].list;
    try mem.requireContainerArena(vm, lst.arena_ctrl, lst.arena_gen, "__listPush");
    lst.items = try mem.pushArray(vm, arenaOpt(lst.arena_ctrl), lst.arena_ctrl, lst.items, args[1]);
    return args[0];
}

fn listPop(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    if (args[0] != .list) return error.TypeError;
    const lst = args[0].list;
    try mem.requireContainerArena(vm, lst.arena_ctrl, lst.arena_gen, "__listPop");
    if (lst.items.count == 0) return .null;
    lst.items.count -= 1;
    return vm.arrayElemConst(lst.items, lst.items.count);
}

fn listGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .list or args[1] != .i64) return error.TypeError;
    const lst = args[0].list;
    try mem.requireContainerArena(vm, lst.arena_ctrl, lst.arena_gen, "__listGet");
    const idx: usize = @intCast(args[1].i64);
    if (idx >= lst.items.count) return error.IndexOutOfBounds;
    return vm.arrayElemConst(lst.items, @intCast(idx));
}

fn listSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .list or args[1] != .i64) return error.TypeError;
    const lst = args[0].list;
    try mem.requireContainerArena(vm, lst.arena_ctrl, lst.arena_gen, "__listSet");
    const idx: usize = @intCast(args[1].i64);
    if (idx >= lst.items.count) return error.IndexOutOfBounds;
    vm.arrayElemPtr(lst.items, @intCast(idx)).* = args[2];
    return args[2];
}

fn listLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    if (args[0] != .list) return error.TypeError;
    const lst = args[0].list;
    try mem.requireContainerArena(vm, lst.arena_ctrl, lst.arena_gen, "__listLen");
    return .{ .i64 = @intCast(lst.items.count) };
}

pub fn register(vm: *VMState) !void {
    list_create_n = .{ .name = "__listCreate", .func = listCreate, .arity = 1 };
    list_create_immortal_n = .{ .name = "__listCreateImmortal", .func = listCreateImmortal, .arity = 0 };
    list_push_n = .{ .name = "__listPush", .func = listPush, .arity = 2 };
    list_pop_n = .{ .name = "__listPop", .func = listPop, .arity = 1 };
    list_get_n = .{ .name = "__listGet", .func = listGet, .arity = 2 };
    list_set_n = .{ .name = "__listSet", .func = listSet, .arity = 3 };
    list_len_n = .{ .name = "__listLen", .func = listLen, .arity = 1 };
    try vm.defineGlobal("__listCreate", .{ .native = &list_create_n });
    try vm.defineGlobal("__listCreateImmortal", .{ .native = &list_create_immortal_n });
    try vm.defineGlobal("__listPush", .{ .native = &list_push_n });
    try vm.defineGlobal("__listPop", .{ .native = &list_pop_n });
    try vm.defineGlobal("__listGet", .{ .native = &list_get_n });
    try vm.defineGlobal("__listSet", .{ .native = &list_set_n });
    try vm.defineGlobal("__listLen", .{ .native = &list_len_n });
}
