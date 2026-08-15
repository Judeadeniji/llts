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
        .ptr => |p| .{ .i64 = vm.slot(p - 1).*.i64 },
        .name => |idx| .{ .i64 = @intCast(vm.chunk.stringAt(idx).len) },
        .slice => |s| .{ .i64 = s.len },
        .bytes => |b| .{ .i64 = b.len },
        .array => |a| .{ .i64 = a.count },
        .buffer => |buf| .{ .i64 = @intCast(buf.bytes.items.len) },
        else => .{ .i64 = 0 },
    };
}

pub fn register(vm: *VMState) !void {
    len_native = .{ .name = "len", .func = lenFn, .arity = 1 };
    try vm.defineGlobal("len", .{ .native = &len_native });
}
