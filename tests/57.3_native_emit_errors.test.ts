/**
 * Native pipeline 57.3 — `--emit` rejection paths.
 *
 * zig's own capability boundaries must surface verbatim (implib only builds
 * for a Windows DLL), and kinds we do not know must be rejected by the CLI
 * before zig runs, listing the supported set.
 *
 * Siblings: 57.1 (linked binary), 57.2 (green artifacts).
 */
import { test, expect } from "bun:test";
import * as path from "node:path";
import { runCli, withNativeProgram, nativeStagedLeftovers } from "./helpers";

test("--emit=implib surfaces zig's Windows-DLL-only rejection verbatim", () => {
  withNativeProgram((sourcePath, dir) => {
    const libPath = path.join(dir, "prog.lib");
    const build = runCli(["build", sourcePath, "--emit=implib", "-o", libPath]);
    expect(build.exitCode).not.toBe(0);
    expect(build.stderr).toContain("Windows DLL");
    expect(build.stderr).not.toContain("Native compile failed");

    expect(nativeStagedLeftovers()).toEqual([]);
  });
}, 180_000);

test("--emit with an unknown kind is rejected before zig runs", () => {
  withNativeProgram((sourcePath, dir) => {
    const build = runCli([
      "build",
      sourcePath,
      "--emit=wasm",
      "-o",
      path.join(dir, "nope"),
    ]);
    expect(build.exitCode).not.toBe(0);
    expect(build.stderr).toContain("Unknown --emit kind 'wasm'");
    expect(build.stderr).toContain(
      "bin, asm, llvm-ir, llvm-bc, h, docs, implib",
    );

    expect(nativeStagedLeftovers()).toEqual([]);
  });
});
