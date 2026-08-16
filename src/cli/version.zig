const std = @import("std");
const zli = @import("zli");

pub const VERSION = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub fn print() void {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}.{d}.{d}\n", .{ VERSION.major, VERSION.minor, VERSION.patch }) catch return;
    @import("llts").io.writeStdout(str);
}

pub fn versionCmd(ctx: zli.CommandContext) !void {
    _ = ctx;
    print();
}
