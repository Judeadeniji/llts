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
    const max_memory = common.getMaxMemory(ctx.allocator, ctx);
    const comptime_iters = common.getComptimeMaxLoopIterations(ctx.allocator, ctx);

    var program_args: []const []const u8 = &[_][]const u8{};
    if (ctx.positional_args.len > 1) {
        program_args = ctx.positional_args[1..];
    }

    if (llts.serialize.isBytecodePath(file)) {
        try pipeline.runBytecode(ctx.allocator, file, program_args, max_memory);
    } else {
        try pipeline.runFile(ctx.allocator, file, release, strict, program_args, max_memory, comptime_iters);
    }
}
