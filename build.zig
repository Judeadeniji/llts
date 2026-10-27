const std = @import("std");

/// Builds each tool a second time in ReleaseSafe and registers the `release`
/// step that installs them over zig-out/. Modules are separate instances from
/// the Debug ones because optimize mode is baked into a module at creation time.
/// Returns the install step so test runners can reuse the fast binaries.
fn addReleaseTools(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const opt: std.builtin.OptimizeMode = .ReleaseSafe;
    const release = b.step("release", "Build llts, llts-lsp and llts-tokenize-zig in ReleaseSafe and install");

    const zli = b.dependency("zli", .{ .target = target, .optimize = opt });

    const llts_mod = b.addModule("llts-rel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = opt,
    });
    llts_mod.link_libc = true;

    const tools = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "llts", .root = "src/main.zig" },
        .{ .name = "llts-tokenize-zig", .root = "self_hosted/tools/dump_zig_tokens.zig" },
        .{ .name = "llts-lsp", .root = "src/lsp/server.zig" },
    };

    for (tools) |t| {
        const exe = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(t.root),
                .target = target,
                .optimize = opt,
                .imports = &.{
                    .{ .name = "llts", .module = llts_mod },
                    .{ .name = "zli", .module = zli.module("zli") },
                },
            }),
        });
        exe.root_module.link_libc = true;
        const install = b.addInstallArtifact(exe, .{});
        release.dependOn(&install.step);
    }
    return release;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zli = b.dependency("zli", .{
        .target = target,
        .optimize = optimize,
    });
    const zli_mod = zli.module("zli");

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_mod.link_libc = true;

    const llts_mod = b.addModule("llts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const tokenize_zig = b.addExecutable(.{
        .name = "llts-tokenize-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("self_hosted/tools/dump_zig_tokens.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "llts", .module = llts_mod },
            },
        }),
    });
    tokenize_zig.root_module.link_libc = true;
    b.installArtifact(tokenize_zig);

    const lsp_exe = b.addExecutable(.{
        .name = "llts-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "llts", .module = llts_mod },
            },
        }),
    });
    lsp_exe.root_module.link_libc = true;
    b.installArtifact(lsp_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run llts");
    run_step.dependOn(&run_cmd.step);

    // `zig build release` — same three tools built in ReleaseSafe and installed
    // over zig-out/. A Debug compiler spends ~40x longer in the typechecker than
    // a ReleaseSafe one, so this is the mode you want for everyday `llts build`.
    // `zig build` still produces Debug (better panics/traces while hacking on it).
    const release_install = addReleaseTools(b, target);

    // const mod_tests = b.addTest(.{
    //     .root_module = llts_mod,
    // });
    // const run_mod_tests = b.addRunArtifact(mod_tests);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.step.dependOn(release_install);
    run_integration.setCwd(b.path("."));

    const lsp_e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lsp_e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lsp_e2e = b.addRunArtifact(lsp_e2e_tests);
    run_lsp_e2e.step.dependOn(release_install);
    run_lsp_e2e.setCwd(b.path("."));

    const lsp_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "llts", .module = llts_mod },
            },
        }),
    });
    const run_lsp_unit = b.addRunArtifact(lsp_unit_tests);

    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_mod },
            },
        }),
    });
    runtime_tests.root_module.link_libc = true;
    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    const runtime_test_step = b.step("runtime-test", "Run native runtime unit tests");
    runtime_test_step.dependOn(&run_runtime_tests.step);

    const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_integration.step);
    test_step.dependOn(&run_lsp_e2e.step);
    test_step.dependOn(&run_lsp_unit.step);
    test_step.dependOn(&run_runtime_tests.step);
}
