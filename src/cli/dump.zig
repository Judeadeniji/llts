const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const common = @import("common.zig");
const pipeline = @import("pipeline.zig");

pub fn execute(ctx: zli.CommandContext) !void {
    common.setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const file = ctx.getArg("file").?;
    const out_val = ctx.flag("output", []const u8);
    const out_path: ?[]const u8 = if (out_val.len > 0) out_val else null;

    if (llts.serialize.isBytecodePath(file)) {
        common.failExit("Cannot dump bytecode from a .llb file; use a .lls source\n", .{});
    }

    try pipeline.dumpFile(ctx.allocator, file, release, out_path);
}
