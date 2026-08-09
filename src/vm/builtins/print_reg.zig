const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const print_fmt = @import("print.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var print_native: NativeFunction = undefined;

fn printFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(vm.allocator, ' ');
        try print_fmt.writeValue(vm, &buf, a);
    }
    try buf.append(vm.allocator, '\n');
    // posix.write: Bun's spawnSync does not capture Zig's buffered File.stdout writer
    _ = try std.posix.write(std.posix.STDOUT_FILENO, buf.items);
    return .null;
}

pub fn register(vm: *VMState) !void {
    print_native = .{
        .name = "print",
        .func = printFn,
        .arity = -1,
    };
    try vm.globals.put("print", .{ .native = &print_native });
}
