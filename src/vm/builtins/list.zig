const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var list_create_n: NativeFunction = undefined;
var list_push_n: NativeFunction = undefined;
var list_pop_n: NativeFunction = undefined;
var list_get_n: NativeFunction = undefined;
var list_set_n: NativeFunction = undefined;
var list_len_n: NativeFunction = undefined;

fn listCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const lst = try vm.allocList();
    return .{ .list = lst };
}

fn listPush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .list) return error.TypeError;
    try args[0].list.items.append(vm.allocator, args[1]);
    return args[0];
}

fn listPop(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    if (args[0] != .list) return error.TypeError;
    if (args[0].list.items.pop()) |v| return v else return .null;
}

fn listGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2) return error.ArityError;
    if (args[0] != .list or args[1] != .i64) return error.TypeError;
    const idx: usize = @intCast(args[1].i64);
    if (idx >= args[0].list.items.items.len) return error.IndexOutOfBounds;
    return args[0].list.items.items[idx];
}

fn listSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 3) return error.ArityError;
    if (args[0] != .list or args[1] != .i64) return error.TypeError;
    const idx: usize = @intCast(args[1].i64);
    if (idx >= args[0].list.items.items.len) return error.IndexOutOfBounds;
    args[0].list.items.items[idx] = args[2];
    return args[2];
}

fn listLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    if (args[0] != .list) return error.TypeError;
    return .{ .i64 = @intCast(args[0].list.items.items.len) };
}

pub fn register(vm: *VMState) !void {
    list_create_n = .{ .name = "__listCreate", .func = listCreate, .arity = 0 };
    list_push_n = .{ .name = "__listPush", .func = listPush, .arity = 2 };
    list_pop_n = .{ .name = "__listPop", .func = listPop, .arity = 1 };
    list_get_n = .{ .name = "__listGet", .func = listGet, .arity = 2 };
    list_set_n = .{ .name = "__listSet", .func = listSet, .arity = 3 };
    list_len_n = .{ .name = "__listLen", .func = listLen, .arity = 1 };
    try vm.defineGlobal("__listCreate", .{ .native = &list_create_n });
    try vm.defineGlobal("__listPush", .{ .native = &list_push_n });
    try vm.defineGlobal("__listPop", .{ .native = &list_pop_n });
    try vm.defineGlobal("__listGet", .{ .native = &list_get_n });
    try vm.defineGlobal("__listSet", .{ .native = &list_set_n });
    try vm.defineGlobal("__listLen", .{ .native = &list_len_n });
}
