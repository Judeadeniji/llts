/**
 * Phase 5.3: Release-mode soundness verification.
 *
 * `--release` only strips debug-only bytecode (OP_LINE source maps and
 * OP_ASSERT_TYPE). It must NOT weaken *static* soundness (compile rejections
 * are produced by the typecheck pass regardless of flags) nor the *runtime*
 * soundness traps (overflow, bounds), which are real VM aborts rather than
 * debug assertions.
 */
import { test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { runSource, runSourceWithFlags } from "./helpers";

const FIXTURES = path.join(import.meta.dir, "compile_fails");

// --- valid programs behave identically ------------------------------------

test("release runs a valid program and prints the same output", () => {
	const src = `
@func add(x: int, y: int): int { return x + y; }
pub @func main() {
    $sum = 0;
    @for (0..5) |i| { sum = sum + i; }
    print(add(sum, 32));
}
`;
	const debug = runSource(src);
	const release = runSourceWithFlags(src, ["-r"]);
	if (debug.exitCode !== 0) throw new Error(`debug run failed: ${debug.stderr}`);
	if (release.exitCode !== 0)
		throw new Error(`release run failed: ${release.stderr}`);
	if (release.stdout !== debug.stdout) {
		throw new Error(
			`release output ${JSON.stringify(release.stdout)} != debug ${JSON.stringify(debug.stdout)}`,
		);
	}
});

// --- static rejections are retained ---------------------------------------

const staticCases: Array<{ file: string; needle: string; strict: boolean }> = [
	{ file: "non_exhaustive_switch.lls", needle: "@switch is missing enum variants", strict: false },
	{ file: "div_by_zero_const.lls", needle: "division by zero in constant expression", strict: false },
	{ file: "null_to_pointer.lls", needle: "not assignable to '*i64'", strict: false },
	{ file: "arena_local_escape.lls", needle: "escapes its arena region", strict: false },
	{ file: "const_overflow.lls", needle: "integer overflow in constant expression", strict: false },
	{ file: "unannotated_param.lls", needle: "explicit type annotation", strict: true },
	{ file: "missing_struct_field.lls", needle: "missing required field", strict: true },
	{ file: "truthiness_coercion.lls", needle: "must be boolean", strict: true },
];

for (const c of staticCases) {
	test(`release still rejects ${c.file}`, () => {
		const source = fs.readFileSync(path.join(FIXTURES, c.file), "utf-8");
		const flags = c.strict ? ["-r", "-s"] : ["-r"];
		const res = runSourceWithFlags(source, flags);
		const combined = res.stderr + res.stdout;
		if (res.exitCode === 0) {
			throw new Error(`${c.file}: compiled under release but should be rejected`);
		}
		if (!combined.includes(c.needle)) {
			throw new Error(
				`${c.file}: expected ${JSON.stringify(c.needle)} under release, got:\n${combined}`,
			);
		}
	});
}

// --- runtime traps are retained -------------------------------------------

test("release retains the checked-overflow trap", () => {
	const res = runSourceWithFlags(
		`
$b: u8 = 250;
print(b + 10);
`,
		["-r"],
	);
	if (res.exitCode === 0) throw new Error("overflow did not trap in release");
	if (!res.stderr.includes("integer overflow")) {
		throw new Error(`missing overflow diagnostic:\n${res.stderr}`);
	}
});

test("release retains the bounds trap for dynamic indices", () => {
	const res = runSourceWithFlags(
		`
$a = [1, 2, 3];
$i = 9;
print(a[i]);
`,
		["-r"],
	);
	if (res.exitCode === 0) throw new Error("bounds violation did not trap in release");
	if (!res.stderr.includes("out of bounds")) {
		throw new Error(`missing bounds diagnostic:\n${res.stderr}`);
	}
});
