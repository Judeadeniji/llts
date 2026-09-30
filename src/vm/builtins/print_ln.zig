const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const fmt_mod = @import("fmt.zig");

const VMState = state_mod.VMState;
const NativeFunction = value.NativeFunction;

var print_ln_native: NativeFunction = undefined;

pub fn register(vm: *VMState) !void {
    print_ln_native = .{ .name = "__printLn", .func = fmt_mod.printLnFn, .arity = -1 };
    try vm.defineGlobal("__printLn", .{ .native = &print_ln_native });
}
