const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var len_native: NativeFunction = undefined;

fn lenFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    return switch (args[0]) {
        .ptr => |p| .{ .int = vm.memory[@intCast(p - 1)] },
        .name => |idx| .{ .int = @intCast(vm.chunk.stringAt(idx).len) },
        else => .{ .int = 0 },
    };
}

pub fn register(vm: *VMState) !void {
    len_native = .{ .name = "len", .func = lenFn, .arity = 1 };
    try vm.globals.put("len", .{ .native = &len_native });
}
