const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const common = @import("common.zig");
const pipeline = @import("pipeline.zig");

pub fn execute(ctx: zli.CommandContext) !void {
    common.setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const strict = ctx.flag("strict", bool);
    const file = ctx.getArg("file").?;
    const out_path = ctx.flag("output", []const u8);
    const comptime_iters = common.getComptimeMaxLoopIterations(ctx.allocator, ctx);

    if (llts.serialize.isBytecodePath(file)) {
        common.failExit("Cannot compile a .llb file; use a .lls source\n", .{});
    }

    try pipeline.compileToFile(ctx.allocator, file, release, strict, out_path, comptime_iters);
}
