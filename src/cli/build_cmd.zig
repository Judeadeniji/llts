const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const common = @import("common.zig");
const pipeline = @import("pipeline.zig");

pub fn execute(ctx: zli.CommandContext) !void {
    common.setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const flag_native = ctx.flag("native", bool);
    const flag_emit_bin = ctx.flag("emit-bin", bool);
    const flag_emit_zig = ctx.flag("emit-zig", bool);
    const flag_emit_asm = ctx.flag("emit-asm", bool);
    _ = ctx.flag("emit-bytecode", bool);

    const is_native = flag_native or flag_emit_bin or flag_emit_asm;
    const is_emit_zig = flag_emit_zig;

    // Native targets and Zig emission require strict mode by default.
    const strict_default = is_native or is_emit_zig;
    const strict = ctx.flag("strict", bool) or strict_default;

    const file = ctx.getArg("file").?;
    const out_val = ctx.flag("output", []const u8);
    const comptime_iters = common.getComptimeMaxLoopIterations(ctx.allocator, ctx);

    if (llts.serialize.isBytecodePath(file)) {
        common.failExit("Cannot compile a .llb file; use a .lls source\n", .{});
    }

    if (is_emit_zig) {
        const out_path = if (out_val.len > 0) out_val else null;
        const runtime_path = common.getRuntimePath(ctx);
        try pipeline.emitZig(ctx.allocator, file, release, strict, out_path, comptime_iters, runtime_path);
        return;
    }

    if (is_native) {
        const out_path = if (out_val.len > 0) out_val else "out";
        const zig_bin = common.getZigBin(ctx.allocator, ctx);
        const target = common.getTarget(ctx);
        const opt = common.getOptimize(ctx);
        const runtime_path = common.getRuntimePath(ctx);
        const zig_args = try common.getZigArgs(ctx.allocator, ctx);
        defer {
            for (zig_args) |arg| ctx.allocator.free(arg);
            ctx.allocator.free(zig_args);
        }

        const emit_mode: llts.pipeline.EmitZigOptions.EmitMode = if (flag_emit_asm)
            .asm_code
        else
            .bin;

        try pipeline.compileNative(
            ctx.allocator,
            file,
            release,
            strict,
            out_path,
            comptime_iters,
            zig_bin,
            target,
            opt,
            emit_mode,
            runtime_path,
            zig_args,
        );
    } else {
        const out_path = if (out_val.len > 0) out_val else "out.llb";
        try pipeline.compileToFile(ctx.allocator, file, release, strict, out_path, comptime_iters);
    }
}
