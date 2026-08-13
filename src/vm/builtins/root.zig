const std = @import("std");
const state_mod = @import("../state.zig");
const print_mod = @import("print.zig");
const print_ln_mod = @import("print_ln.zig");
const len_mod = @import("len.zig");
const mem_mod = @import("mem.zig");
const math_mod = @import("math.zig");
const string_mod = @import("string.zig");
const io_mod = @import("io.zig");
const time_mod = @import("time.zig");
const os_mod = @import("os.zig");
const http_mod = @import("http.zig");
const json_mod = @import("json_builtin.zig");
const list_mod = @import("list.zig");
const map_mod = @import("map.zig");
const buffer_mod = @import("buffer.zig");
const log_mod = @import("log.zig");

pub fn registerBuiltins(vm: *state_mod.VMState) !void {
    try print_mod.register(vm);
    try print_ln_mod.register(vm);
    try log_mod.register(vm);
    try len_mod.register(vm);
    try mem_mod.register(vm);
    try math_mod.register(vm);
    try string_mod.register(vm);
    try io_mod.register(vm);
    try time_mod.register(vm);
    try os_mod.register(vm);
    try http_mod.register(vm);
    try json_mod.register(vm);
    try list_mod.register(vm);
    try map_mod.register(vm);
    try buffer_mod.register(vm);
}
