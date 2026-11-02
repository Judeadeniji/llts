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
    const emit_kind = ctx.flag("emit", []const u8);
    _ = ctx.flag("emit-bytecode", bool);

    if (flag_emit_zig) {
        common.failExit("`llts run` cannot emit Zig source; use `llts emit-zig`", .{});
    }
    if (flag_emit_asm or (emit_kind.len > 0 and !std.mem.eql(u8, emit_kind, "bin"))) {
        common.failExit("`llts run` only runs a native binary; use `llts build --native --emit=...` for other artifacts", .{});
    }

    const is_native = flag_native or flag_emit_bin or std.mem.eql(u8, emit_kind, "bin");
    // Native targets require strict mode by default (same as `build --native`).
    const strict = ctx.flag("strict", bool) or is_native;

    const file = ctx.getArg("file").?;
    const max_memory = common.getMaxMemory(ctx.allocator, ctx);
    const comptime_iters = common.getComptimeMaxLoopIterations(ctx.allocator, ctx);

    var program_args: []const []const u8 = &[_][]const u8{};
    if (ctx.positional_args.len > 1) {
        program_args = ctx.positional_args[1..];
    }

    if (is_native) {
        if (llts.serialize.isBytecodePath(file)) {
            common.failExit("Cannot run bytecode with --native; pass a .lls source file", .{});
        }

        const zig_bin = try common.getZigBin(ctx.allocator, ctx);
        errdefer ctx.allocator.free(zig_bin);
        const target = common.getTarget(ctx);
        const opt = common.getOptimize(ctx);
        const runtime_path = common.getRuntimePath(ctx);
        const zig_args = try common.getZigArgsFlagsOnly(ctx.allocator, ctx);
        errdefer {
            for (zig_args) |arg| ctx.allocator.free(arg);
            ctx.allocator.free(zig_args);
        }

        const code = try pipeline.runNative(
            ctx.allocator,
            file,
            release,
            strict,
            program_args,
            comptime_iters,
            zig_bin,
            target,
            opt,
            runtime_path,
            zig_args,
        );
        // Free before process.exit — exit skips `defer` and GPA would report leaks.
        for (zig_args) |arg| ctx.allocator.free(arg);
        ctx.allocator.free(zig_args);
        ctx.allocator.free(zig_bin);
        std.process.exit(code);
    }

    if (llts.serialize.isBytecodePath(file)) {
        try pipeline.runBytecode(ctx.allocator, file, program_args, max_memory);
    } else {
        try pipeline.runFile(ctx.allocator, file, release, strict, program_args, max_memory, comptime_iters);
    }
}
