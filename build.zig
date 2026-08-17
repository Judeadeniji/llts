const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zli = b.dependency("zli", .{
        .target = target,
        .optimize = optimize,
    });
    const zli_mod = zli.module("zli");

    // llvm-zig also exposes a `clang` module; we only need LLVM IR/bitcode APIs.
    // Linking clang pulls `clang-21` and breaks Manjaro hosts that only have libLLVM-21.
    const llvm_dep = b.dependency("llvm", .{
        .target = target,
        .optimize = optimize,
    });
    const llvm_mod = llvm_dep.module("llvm");

    const llts_mod = b.addModule("llts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llvm", .module = llvm_mod },
        },
    });
    llts_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "llts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "llts", .module = llts_mod },
                .{ .name = "zli", .module = zli_mod },
            },
        }),
    });
    exe.root_module.addImport("llvm", llvm_mod);
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run llts");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = llts_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.step.dependOn(b.getInstallStep());
    run_integration.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_integration.step);
}
