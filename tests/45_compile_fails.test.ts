/**
 * Phase 5.1: Negative conformance suite.
 *
 * Every fixture under `tests/compile_fails/` is a program that MUST be rejected
 * at compile time. Each file declares the diagnostic it must produce:
 *
 *     # expect: <substring of the diagnostic>
 *     # mode: strict        (optional; default is normal mode)
 *
 * The runner compiles the fixture (optionally with `--strict`) and asserts a
 * non-zero exit whose combined output contains the expected substring.
 */
import { test, expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { runFile, runFileStrict } from "./helpers";

const DIR = path.join(import.meta.dir, "compile_fails");

const fixtures = fs
	.readdirSync(DIR)
	.filter((f) => f.endsWith(".lls"))
	.sort();

test("compile_fails fixtures exist", () => {
	expect(fixtures.length).toBeGreaterThan(0);
});

for (const name of fixtures) {
	test(`compile_fails: ${name}`, () => {
		const file = path.join(DIR, name);
		const source = fs.readFileSync(file, "utf-8");
		const lines = source.split("\n");

		const expectLine = lines.find((l) => l.trimStart().startsWith("# expect:"));
		if (!expectLine) {
			throw new Error(
				`${name}: missing '# expect: <substring>' header comment`,
			);
		}
		const needle = expectLine.slice(expectLine.indexOf("# expect:") + "# expect:".length).trim();
		if (needle.length === 0) {
			throw new Error(`${name}: empty '# expect:' substring`);
		}

		const strict = lines.some((l) => l.trim() === "# mode: strict");
		const res = strict ? runFileStrict(file) : runFile(file);
		const combined = res.stderr + res.stdout;

		if (res.exitCode === 0) {
			throw new Error(
				`${name}: expected a compile failure but the program succeeded.\n` +
					`stdout:\n${res.stdout}`,
			);
		}
		if (!combined.includes(needle)) {
			throw new Error(
				`${name}: expected diagnostic containing ${JSON.stringify(needle)}\n` +
					`but got:\n${combined}`,
			);
		}
	});
}
