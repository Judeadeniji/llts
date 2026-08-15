const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var map_create_n: NativeFunction = undefined;
var map_set_n: NativeFunction = undefined;
var map_get_n: NativeFunction = undefined;
var map_has_n: NativeFunction = undefined;
var map_delete_n: NativeFunction = undefined;
var map_size_n: NativeFunction = undefined;

fn mapCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const mp = try vm.allocMap();
    return .{ .map = mp };
}

fn mapSet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);
    
    const mp = args[0].map;
    const gop = try mp.entries.getOrPut(key);
    if (!gop.found_existing) {
        gop.key_ptr.* = try vm.allocator.dupe(u8, key);
    }
    gop.value_ptr.* = args[2];
    return args[2];
}

fn mapGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);
    
    if (args[0].map.entries.get(key)) |v| {
        return v;
    }
    return .null;
}

fn mapHas(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);
    
    return .{ .bool = args[0].map.entries.contains(key) };
}

fn mapDelete(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const key = try util.valueToStr(vm, args[1], &buf);
    
    if (args[0].map.entries.fetchRemove(key)) |kv| {
        vm.allocator.free(kv.key);
        return .{ .bool = true };
    }
    return .{ .bool = false };
}

fn mapSize(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 1) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    return .{ .i64 = @intCast(args[0].map.entries.count()) };
}

pub fn register(vm: *VMState) !void {
    map_create_n = .{ .name = "__mapCreate", .func = mapCreate, .arity = 0 };
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
