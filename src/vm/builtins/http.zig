const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var fetch_n: NativeFunction = undefined;

fn fetchFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    const url = try util.valueToStr(vm, args[0], &buf1);
    
    var client = std.http.Client{ .allocator = vm.allocator };
    defer client.deinit();
    
    var out: std.io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    
    const fetch_res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &out.writer,
    }) catch |err| {
        return try util.makeError(vm, @errorName(err));
    };
    
    var list: std.ArrayListUnmanaged(Value) = .empty;
    defer list.deinit(vm.allocator);
    
    // index 0: status
    try list.append(vm.allocator, .{ .int = @intCast(@intFromEnum(fetch_res.status)) });
    // index 1: body
    const body_val = try util.writeSlice(vm, out.written());
    try list.append(vm.allocator, body_val);
    
    // Returning an array [status, body]
    return try util.writeArray(vm, list.items);
}

pub fn register(vm: *VMState) !void {
    fetch_n = .{ .name = "__fetch", .func = fetchFn, .arity = 1 };
    try vm.globals.put("__fetch", .{ .native = &fetch_n });
}
