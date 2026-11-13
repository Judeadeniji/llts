const std = @import("std");
const zli = @import("zli");
const llts = @import("llts");
const common = @import("common.zig");
const pipeline = @import("pipeline.zig");

pub fn execute(ctx: zli.CommandContext) !void {
    common.setLogLevel(ctx);
    const release = ctx.flag("release", bool);
    const flag_vm = ctx.flag("vm", bool);
    const flag_emit_bin = ctx.flag("emit-bin", bool);
    const flag_emit_zig = ctx.flag("emit-zig", bool);
    const flag_emit_asm = ctx.flag("emit-asm", bool);
    const emit_kind = ctx.flag("emit", []const u8);
    _ = ctx.flag("emit-bytecode", bool);
    const eval_code = ctx.flag("eval", []const u8);

    if (flag_emit_zig) {
        common.failExit("`llts run` cannot emit Zig source; use `llts emit-zig`", .{});
    }
    if (flag_emit_asm or (emit_kind.len > 0 and !std.mem.eql(u8, emit_kind, "bin"))) {
        common.failExit("`llts run` only runs a native binary; use `llts build --emit=...` for other artifacts", .{});
    }

    const native_requested = flag_emit_bin or std.mem.eql(u8, emit_kind, "bin");
    if (flag_vm and native_requested) {
        common.failExit("`--vm` cannot be combined with native emit flags", .{});
    }
    // Strict typing is on by default for both backends; pass `--strict false`
    // to opt out. Native is the default execution path.
    const strict = ctx.flag("strict", bool);

    const max_memory = common.getMaxMemory(ctx.allocator, ctx);
    const comptime_iters = common.getComptimeMaxLoopIterations(ctx.allocator, ctx);

    if (eval_code.len > 0) {
        const source = try pipeline.prepareEvalSource(ctx.allocator, eval_code);
        defer ctx.allocator.free(source);
        const program_args = ctx.positional_args;

        if (!flag_vm) {
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

            const code = try pipeline.runNativeSource(
                ctx.allocator,
                "[eval]",
                source,
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
            for (zig_args) |arg| ctx.allocator.free(arg);
            ctx.allocator.free(zig_args);
            ctx.allocator.free(zig_bin);
            std.process.exit(code);
        }

        try pipeline.runSource(
            ctx.allocator,
            "[eval]",
            source,
            release,
            strict,
            program_args,
            max_memory,
            comptime_iters,
        );
        return;
    }

    const maybe_file = ctx.getArg("file");
    if (maybe_file == null or maybe_file.?.len == 0) {
        common.failExit("Missing source or bytecode file to run; use `llts run <file>` or `llts -e <code>`", .{});
    }
    const file = maybe_file.?;

    var program_args: []const []const u8 = &[_][]const u8{};
    if (ctx.positional_args.len > 1) {
        program_args = ctx.positional_args[1..];
    }

    // Bytecode files always run on the VM; source files run natively unless
    // `--vm` explicitly selects the VM.
    const is_bytecode = llts.serialize.isBytecodePath(file);
    if (is_bytecode and native_requested) {
        common.failExit("Cannot run a .llb file natively; pass a .lls source file", .{});
    }
    const is_native = !flag_vm and !is_bytecode;

    if (is_native) {
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

    if (is_bytecode) {
        try pipeline.runBytecode(ctx.allocator, file, program_args, max_memory);
    } else {
        try pipeline.runFile(ctx.allocator, file, release, strict, program_args, max_memory, comptime_iters);
    }
}
