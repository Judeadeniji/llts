const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const common = @import("common.zig");
const pipeline = @import("pipeline.zig");

pub fn execute(ctx: zli.CommandContext) !void {
    common.setLogLevel(ctx);
    const file = ctx.getArg("file").?;
    const out_path = ctx.flag("output", []const u8);
    const ir_path = ctx.flag("emit-llvm", []const u8);
    const release = ctx.flag("release", bool);

    if (llts.serialize.isBytecodePath(file)) {
        common.failExit("Cannot emit LLVM IR from a .llb file; use a .lls source\n", .{});
    }

    try pipeline.emitLlvm(ctx.allocator, file, out_path, ir_path, release);
}
