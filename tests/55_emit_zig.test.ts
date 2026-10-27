/**
 * Phase 2 native emitter: `llts emit-zig` must produce Zig that compiles and
 * matches the bytecode VM for the supported subset (functions, locals,
 * scalar arithmetic, strings, print, top-level code).
 */
import { test, expect } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runCli, runFile } from "./helpers";

const ROOT = path.resolve(import.meta.dir, "..");
const ZIG_BIN = process.env.LLTS_ZIG_BIN || "zig";

interface Emitted {
	sourcePath: string;
	outputPath: string;
	cleanup: () => void;
}

function emitZig(source: string): Emitted {
	const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
	const sourcePath = path.join(os.tmpdir(), `llts_emit_zig_${id}.lls`);
	const outputPath = path.join(ROOT, `.tmp_emit_zig_${id}.zig`);
	fs.writeFileSync(sourcePath, source, "utf-8");
	return {
		sourcePath,
		outputPath,
		cleanup: () => {
			if (fs.existsSync(sourcePath)) fs.unlinkSync(sourcePath);
			if (fs.existsSync(outputPath)) fs.unlinkSync(outputPath);
		},
	};
}

function runEmitted(outputPath: string) {
	const result = spawnSync([ZIG_BIN, "run", "-lc", outputPath], { cwd: ROOT });
	return {
		stdout: result.stdout.toString(),
		stderr: result.stderr.toString(),
		exitCode: result.exitCode ?? 1,
	};
}

function expectParity(source: string, checkGenerated?: (code: string) => void) {
	const emitted = emitZig(source);
	try {
		const emit = runCli(["emit-zig", emitted.sourcePath, "-o", emitted.outputPath]);
		expect(emit.stderr + emit.stdout).toBe("");
		expect(emit.exitCode).toBe(0);
		if (checkGenerated) {
			checkGenerated(fs.readFileSync(emitted.outputPath, "utf-8"));
		}

		const native = runEmitted(emitted.outputPath);
		const vm = runFile(emitted.sourcePath);
		expect(native.exitCode).toBe(vm.exitCode);
		expect(native.stdout).toBe(vm.stdout);
	} finally {
		emitted.cleanup();
	}
}

test("emits functions, locals, and scalar arithmetic", () => {
	expectParity(`
@func add(a: int, b: int): int {
    return a + b;
}

pub @func main() {
    $a = 20;
    $b = 22;
    print(add(a, b));
    print(a * b - 10);
    print(-a);
    print(1.25 * 2.0);
}
`, (generated) => {
	expect(generated).not.toContain("@as(i64, lls_");
	expect(generated).not.toContain("@bitCast(lls_");
});
}, 60_000);

test("emits strings, booleans, len, and @as", () => {
	expectParity(`
pub @func main() {
    $s: string = "foo" + "bar";
    print(s);
    print(len(s));
    print(s == "foobar");
    print("a" != "b");
    print(@as(u8, 42));
    print(@as(int, @as(u8, 42)));
}
`);
}, 60_000);

test("emits top-level globals before main", () => {
	expectParity(`
@const $base = 10;
$counter = 0;
print("top");
counter = counter + 1;
print(counter);

@func get(): int {
    return base;
}

pub @func main() {
    print(get());
    print(counter);
}
`);
}, 60_000);

test("runtime traps keep the VM error message and exit code", () => {
	const emitted = emitZig(`
@func div(a: int, b: int): int {
    return a / b;
}

pub @func main() {
    print("before");
    print(div(1, 0));
}
`);
	try {
		const emit = runCli(["emit-zig", emitted.sourcePath, "-o", emitted.outputPath]);
		expect(emit.exitCode).toBe(0);

		const native = runEmitted(emitted.outputPath);
		const vm = runFile(emitted.sourcePath);
		expect(native.exitCode).toBe(1);
		expect(vm.exitCode).toBe(1);
		expect(native.stdout).toBe("before\n");
		expect(vm.stdout).toBe("before\n");
		expect(native.stderr).toContain("Error: Division by zero");
		expect(vm.stderr).toContain("Error: Division by zero");
	} finally {
		emitted.cleanup();
	}
}, 60_000);

test("unsupported control flow is rejected with a Phase 3 diagnostic", () => {
	const emitted = emitZig(`
pub @func main() {
    $x = 1;
    @if (x == 1) {
        print(x);
    }
}
`);
	try {
		const emit = runCli(["emit-zig", emitted.sourcePath, "-o", emitted.outputPath]);
		expect(emit.exitCode).not.toBe(0);
		expect(emit.stderr + emit.stdout).toContain("does not support if_expr");
		expect(fs.existsSync(emitted.outputPath)).toBe(false);
	} finally {
		emitted.cleanup();
	}
}, 60_000);
