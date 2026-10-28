/**
 * Native pipeline 57.2 — non-binary `-femit-*` artifacts.
 *
 * Every artifact kind zig's `build-exe` advertises must be selectable from
 * `llts build`: assembly through the legacy `--emit-asm` flag, and LLVM IR /
 * html docs through the generic `--emit=<kind>` flag (which also proves it
 * implies `--native`). `llvm-bc` follows the llvm-ir code path and `-femit-h`
 * is a zig 0.15.2 no-op — both were probed manually.
 *
 * Siblings: 57.1 (linked binary), 57.3 (emit-flag rejections).
 */
import { test, expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { runCli, withNativeProgram, nativeStagedLeftovers } from "./helpers";

test("build --native --emit-asm writes assembly without linking a binary", () => {
	withNativeProgram((sourcePath, dir) => {
		const asmPath = path.join(dir, "prog.s");
		const build = runCli(["build", sourcePath, "--native", "--emit-asm", "-o", asmPath]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(asmPath)).toBe(true);

		const text = fs.readFileSync(asmPath, "utf-8");
		expect(text.length).toBeGreaterThan(0);
		expect(text).toContain(".text");

		expect(nativeStagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("--emit=llvm-ir implies --native and writes optimized LLVM IR", () => {
	withNativeProgram((sourcePath, dir) => {
		const llPath = path.join(dir, "prog.ll");
		const build = runCli(["build", sourcePath, "--emit=llvm-ir", "-o", llPath]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(llPath)).toBe(true);

		const text = fs.readFileSync(llPath, "utf-8");
		expect(text).toContain("; ModuleID");
		expect(text).toContain("target triple");

		expect(nativeStagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("--emit=docs writes the zig html docs directory", () => {
	withNativeProgram((sourcePath, dir) => {
		const docsDir = path.join(dir, "prog_docs");
		const build = runCli(["build", sourcePath, "--emit=docs", "-o", docsDir]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(path.join(docsDir, "index.html"))).toBe(true);

		expect(nativeStagedLeftovers()).toEqual([]);
	});
}, 180_000);
