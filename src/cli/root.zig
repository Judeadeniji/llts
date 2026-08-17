const std = @import("std");
const zli = @import("zli");

const flags = @import("flags.zig");
const common = @import("common.zig");
const version = @import("version.zig");
const run = @import("run.zig");
const build_cmd = @import("build_cmd.zig");
const dump = @import("dump.zig");
const smoke = @import("smoke.zig");
const emit = @import("emit.zig");

fn showHelp(ctx: zli.CommandContext) !void {
    if (ctx.flag("version", bool)) {
        version.print();
        std.process.exit(0);
    }
    common.setLogLevel(ctx);
    try ctx.command.printHelp();
}

pub fn build(stdout: anytype, stdin: anytype, gpa: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "llts",
        .description = "LLTS — a general-purpose language",
        .version = version.VERSION,
    }, showHelp);

    try root.addFlag(flags.log_level);
    try root.addFlag(flags.version_flag);

    const version_sub = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "version",
        .shortcut = "v",
        .description = "Show version information",
    }, version.versionCmd);
    try root.addCommand(version_sub);

    const run_cmd = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "run",
        .description = "Run an LLTS source or bytecode file",
    }, run.execute);
    try flags.addRunFlags(run_cmd);
    try run_cmd.addPositionalArg(.{
        .name = "file",
        .description = "Source (.lls) or bytecode (.llb) file to run",
        .required = true,
    });
    try run_cmd.addPositionalArg(.{
        .name = "args",
        .description = "Arguments forwarded to the program",
        .required = false,
        .variadic = true,
    });
    try root.addCommand(run_cmd);

    const build_sub = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "build",
        .description = "Compile an LLTS source file to bytecode",
    }, build_cmd.execute);
    try flags.addCompileFlags(build_sub);
    try build_sub.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output bytecode file path",
        .type = .String,
        .default_value = .{ .String = "out.llb" },
    });
    try build_sub.addPositionalArg(.{
        .name = "file",
        .description = "Source file to compile",
        .required = true,
    });
    try root.addCommand(build_sub);

    const dump_sub = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "dump",
        .description = "Dump bytecode from an LLTS source file",
    }, dump.execute);
    try flags.addCompileFlags(dump_sub);
    try dump_sub.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output file path",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try dump_sub.addPositionalArg(.{
        .name = "file",
        .description = "Source file to compile and dump",
        .required = true,
    });
    try root.addCommand(dump_sub);

    const emit_sub = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "emit",
        .description = "Emit LLVM bitcode from an LLTS source file",
    }, emit.execute);
    try flags.addCompileFlags(emit_sub);
    try emit_sub.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output bitcode file path",
        .type = .String,
        .default_value = .{ .String = "out.bc" },
    });
    try emit_sub.addFlag(.{
        .name = "emit-llvm",
        .description = "Also write textual LLVM IR (.ll) to this path",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try emit_sub.addPositionalArg(.{
        .name = "file",
        .description = "Source file to compile to LLVM bitcode",
        .required = true,
    });
    try root.addCommand(emit_sub);

    const smoke_sub = try zli.Command.init(stdout, stdin, gpa, .{
        .name = "smoke",
        .description = "Run the smoke test",
    }, smoke.execute);
    try root.addCommand(smoke_sub);

    return root;
}
