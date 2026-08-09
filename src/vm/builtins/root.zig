const std = @import("std");
const state_mod = @import("../state.zig");
const print_mod = @import("print.zig");
const print_ln_mod = @import("print_ln.zig");
const len_mod = @import("len.zig");
const mem_mod = @import("mem.zig");
const math_mod = @import("math.zig");
const string_mod = @import("string.zig");
const io_mod = @import("io.zig");

pub fn registerBuiltins(vm: *state_mod.VMState) !void {
    try print_mod.register(vm);
    try print_ln_mod.register(vm);
    try len_mod.register(vm);
    try mem_mod.register(vm);
    try math_mod.register(vm);
    try string_mod.register(vm);
    try io_mod.register(vm);
}
