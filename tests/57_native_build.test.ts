/**
 * Native pipeline: `llts build --native` must emit runtime Zig, stage it in
 * the working directory, spawn `zig build-exe`, and produce an artifact that
 * matches the VM.
 *
 * Covered here:
 *   - binary output (default): the built binary's stdout/exit code equal `llts run`
 *   - `--emit-asm`: assembly output without a linked binary
 *   - `--emit=<kind>`: implies `--native` and maps onto every zig `-femit-*`
 *     artifact (llvm-ir and docs proven green; implib asserted as zig's
 *     Windows-DLL-only rejection; llvm-bc follows the llvm-ir path and `-femit-h`
 *     is a zig 0.15.2 no-op — both probed manually)
 *   - staging cleanup: no `.llts_native_*.zig` is left behind after success
 *
 * Strict typecheck-before-zig behavior lives in tests/48_native_strict.test.ts;
 * emitted-source parity lives in tests/55_emit_zig.test.ts.
 */
import { test, expect } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runCli, runFile } from "./helpers";

const ROOT = path.resolve(import.meta.dir, "..");

/** Phase 2 + @if subset that the native emitter lowers at parity with the VM. */
const PROGRAM = `
@func dbl(a: int): int { return a * 2; }
@func add(a: int, b: int): int { return a + b; }
@func isEven(a: int): bool { return a % 2 == 0; }

pub @func main() {
	print(21 |> dbl);
	print(10 |> add(5));
	@if (4 |> isEven) {
		print("even");
	}
	print("done");
}
`;

function withTempSource(fn: (sourcePath: string, dir: string) => void) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_native_build_"));
	const sourcePath = path.join(dir, "prog.lls");
	fs.writeFileSync(sourcePath, PROGRAM, "utf-8");
	try {
		fn(sourcePath, dir);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

function stagedLeftovers(): string[] {
	return fs.readdirSync(ROOT).filter((n) => n.startsWith(".llts_native_"));
}

test("build --native links a binary that matches the VM", () => {
	withTempSource((sourcePath, dir) => {
		const out = path.join(dir, "prog_native");
		const build = runCli(["build", sourcePath, "--native", "-o", out]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(out)).toBe(true);

		const native = spawnSync([out], { cwd: ROOT });
		const vm = runFile(sourcePath);
		expect(native.exitCode).toBe(vm.exitCode);
		expect(native.stdout.toString()).toBe(vm.stdout);

		expect(stagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("build --native --emit-asm writes assembly without linking a binary", () => {
	withTempSource((sourcePath, dir) => {
		const asmPath = path.join(dir, "prog.s");
		const build = runCli(["build", sourcePath, "--native", "--emit-asm", "-o", asmPath]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(asmPath)).toBe(true);

		const text = fs.readFileSync(asmPath, "utf-8");
		expect(text.length).toBeGreaterThan(0);
		expect(text).toContain(".text");

		expect(stagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("--emit=llvm-ir implies --native and writes optimized LLVM IR", () => {
	withTempSource((sourcePath, dir) => {
		const llPath = path.join(dir, "prog.ll");
		const build = runCli(["build", sourcePath, "--emit=llvm-ir", "-o", llPath]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(llPath)).toBe(true);

		const text = fs.readFileSync(llPath, "utf-8");
		expect(text).toContain("; ModuleID");
		expect(text).toContain("target triple");

		expect(stagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("--emit=docs writes the zig html docs directory", () => {
	withTempSource((sourcePath, dir) => {
		const docsDir = path.join(dir, "prog_docs");
		const build = runCli(["build", sourcePath, "--emit=docs", "-o", docsDir]);
		expect(build.stderr + build.stdout).toBe("");
		expect(build.exitCode).toBe(0);
		expect(fs.existsSync(path.join(docsDir, "index.html"))).toBe(true);

		expect(stagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("--emit=implib surfaces zig's Windows-DLL-only rejection verbatim", () => {
	withTempSource((sourcePath, dir) => {
		const libPath = path.join(dir, "prog.lib");
		const build = runCli(["build", sourcePath, "--emit=implib", "-o", libPath]);
		expect(build.exitCode).not.toBe(0);
		expect(build.stderr).toContain("Windows DLL");
		expect(build.stderr).not.toContain("Native compile failed");

		expect(stagedLeftovers()).toEqual([]);
	});
}, 180_000);

test("--emit with an unknown kind is rejected before zig runs", () => {
	withTempSource((sourcePath, dir) => {
		const build = runCli(["build", sourcePath, "--emit=wasm", "-o", path.join(dir, "nope")]);
		expect(build.exitCode).not.toBe(0);
		expect(build.stderr).toContain("Unknown --emit kind 'wasm'");
		expect(build.stderr).toContain("bin, asm, llvm-ir, llvm-bc, h, docs, implib");

		expect(stagedLeftovers()).toEqual([]);
	});
});
