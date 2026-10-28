/**
 * Native pipeline 57.1 — `build --native` links a runnable binary.
 *
 * `compileNativeBinary` must emit runtime Zig, stage it in the working
 * directory, spawn `zig build-exe`, and produce a binary whose stdout/exit
 * code match the VM.
 *
 * Siblings: 57.2 (other `-femit-*` artifacts), 57.3 (emit-flag rejections).
 * Strict typecheck-before-zig: tests/48_native_strict.test.ts.
 */
import { test, expect } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as path from "node:path";
import {
	runCli,
	runFile,
	withNativeProgram,
	nativeStagedLeftovers,
} from "./helpers";

const ROOT = path.resolve(import.meta.dir, "..");

test("build --native links a binary that matches the VM", () => {
	withNativeProgram((sourcePath, dir) => {
		const out = path.join(dir, "prog_native");
		const build = runCli(["build", sourcePath, "--native", "-o", out]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(out)).toBe(true);

		const native = spawnSync([out], { cwd: ROOT });
		const vm = runFile(sourcePath);
		expect(native.exitCode).toBe(vm.exitCode);
		expect(native.stdout.toString()).toBe(vm.stdout);

		expect(nativeStagedLeftovers()).toEqual([]);
	});
}, 180_000);
