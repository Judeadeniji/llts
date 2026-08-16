const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");

pub fn execute(ctx: zli.CommandContext) !void {
    var c = llts.Chunk.init(ctx.allocator);
    defer c.deinit();

    const idx = try c.addConstant(.{ .i64 = 42 });
    try c.writeOp(.OP_CONSTANT);
    try c.write(@intCast((idx >> 8) & 0xff));
    try c.write(@intCast(idx & 0xff));
    try c.writeOp(.OP_PRINT);
    try c.write(1);

    try llts.runChunk(ctx.allocator, &c, "smoke", &[_][]const u8{}, 1048576);
}
