/**
 * Native backend prep: strict mode must be ON BY DEFAULT whenever LLTS is
 * compiled natively or lowered to runtime Zig (docs/native-backend.md,
 * Core Architectural Principle #1 "Strict by Default").
 *
 * Covered here:
 *   - `llts emit-zig <file>`            → strict by default
 *   - `llts build --native <file>`      → strict by default
 *   - `--strict=false`                  → explicit opt-out still works
 *   - `llts build <file>` (bytecode)    → stays gradual (non-strict) by default
 *
 * The emitter itself is still a Phase 2/4 stub (`error.NotImplemented`), so
 * these tests assert on the *typecheck* result only — presence/absence of the
 * strict diagnostic — never on emission success.
 */
import { test, expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { runCli } from "./helpers";

const STRICT_NEEDLE =
	"must have an explicit type annotation in strict mode";

/** Unannotated params — rejected under strict, accepted under gradual typing. */
const UNANNOTATED = `@func add(a, b) {
	return a + b;
}

pub @func main() {
	print(add(1, 2));
}
`;

/** Same program, fully annotated — passes strict typechecking. */
const ANNOTATED = `@func add(a: int, b: int): int {
	return a + b;
}

pub @func main() {
	print(add(1, 2));
}
`;

function withTempSource(source: string, fn: (file: string) => void) {
	const file = path.join(
		os.tmpdir(),
		`llts_native_strict_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
	);
	fs.writeFileSync(file, source, "utf-8");
	try {
		fn(file);
	} finally {
		fs.unlinkSync(file);
	}
}

function combined(result: { stderr: string; stdout: string }): string {
	return result.stderr + result.stdout;
}

test("emit-zig typechecks strictly by default", () => {
	withTempSource(UNANNOTATED, (file) => {
		const res = runCli(["emit-zig", file]);
		expect(res.exitCode).not.toBe(0);
		expect(combined(res)).toContain(STRICT_NEEDLE);
	});
});

test("build --native typechecks strictly by default", () => {
	withTempSource(UNANNOTATED, (file) => {
		const res = runCli(["build", "--native", file]);
		expect(res.exitCode).not.toBe(0);
		expect(combined(res)).toContain(STRICT_NEEDLE);
	});
});

test("emit-zig --strict=false opts out of strict mode", () => {
	withTempSource(UNANNOTATED, (file) => {
		const res = runCli(["emit-zig", "--strict=false", file]);
		expect(combined(res)).not.toContain(STRICT_NEEDLE);
	});
});

test("fully annotated program passes the native strict typecheck", () => {
	withTempSource(ANNOTATED, (file) => {
		const res = runCli(["emit-zig", file]);
		expect(combined(res)).not.toContain(STRICT_NEEDLE);
	});
});

test("bytecode build stays gradual (non-strict) by default", () => {
	withTempSource(UNANNOTATED, (file) => {
		const out = path.join(
			os.tmpdir(),
			`llts_native_strict_out_${Date.now()}_${Math.random().toString(36).slice(2)}.llb`,
		);
		try {
			const res = runCli(["build", file, "-o", out]);
			expect(res.exitCode).toBe(0);
			expect(combined(res)).not.toContain(STRICT_NEEDLE);
			expect(fs.existsSync(out)).toBe(true);
		} finally {
			if (fs.existsSync(out)) fs.unlinkSync(out);
		}
	});
});
