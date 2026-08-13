const registry = @import("registry.zig");
const state_mod = @import("../state.zig");

pub fn registerBuiltins(vm: *state_mod.VMState, chunk: *const @import("../../bytecode/chunk.zig").Chunk) !void {
    try registry.registerBuiltins(vm, chunk);
}
