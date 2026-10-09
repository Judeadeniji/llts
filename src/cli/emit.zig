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
    const out_val = ctx.flag("output", []const u8);
    const out_path: ?[]const u8 = if (out_val.len > 0) out_val else null;
    const runtime_path = common.getRuntimePath(ctx);
    const comptime_iters = common.getComptimeMaxLoopIterations(ctx.allocator, ctx);

    if (llts.serialize.isBytecodePath(file)) {
        common.failExit("Cannot emit Zig from a .llb file; use a .lls source\n", .{});
    }

    try pipeline.emitZig(ctx.allocator, file, release, strict, out_path, comptime_iters, runtime_path);
}
