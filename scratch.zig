const std = @import("std");
const value = @import("src/bytecode/value.zig");
pub fn main() void {
    std.debug.print("Size of Value: {}\n", .{@sizeOf(value.Value)});
}
