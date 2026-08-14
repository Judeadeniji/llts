/**
 * LLTS test helpers — spawn the Zig `llts` binary so suite cases stay
 * language-level (Bun is only the test runner).
 */
import { spawnSync } from "bun";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";

const ROOT = path.resolve(import.meta.dir, "..");
const ENTRY = path.join(ROOT, "zig-out/bin/llts");

export interface RunResult {
	stdout: string;
	stderr: string;
	exitCode: number;
	lines: string[];
}

function requireBinary() {
	if (!fs.existsSync(ENTRY)) {
		throw new Error(
			`Missing ${ENTRY}. Run \`zig build\` from the repo root first.`,
		);
	}
}

function hasMain(source: string): boolean {
	return /(?:pub\s+)?@func\s+main\s*\(/.test(source);
}

/** Append an empty `main` so snippet tests stay valid programs. */
function ensureMain(source: string): string {
	if (hasMain(source)) return source;
	return `${source}\npub @func main() {}\n`;
}

/** Compile and run an inline .lls source string. */
export function runSource(source: string): RunResult {
	requireBinary();
	const tmp = path.join(
		os.tmpdir(),
		`llts_test_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
	);
	fs.writeFileSync(tmp, ensureMain(source), "utf-8");
	try {
		return runFile(tmp);
	} finally {
		fs.unlinkSync(tmp);
	}
}

/** Compile and run inline source exactly as written (no injected `main`). */
export function runSourceAsWritten(source: string): RunResult {
	requireBinary();
	const tmp = path.join(
		os.tmpdir(),
		`llts_test_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
	);
	fs.writeFileSync(tmp, source, "utf-8");
	try {
		return runFile(tmp);
	} finally {
		fs.unlinkSync(tmp);
	}
}

/** Compile and run a .lls file (absolute or relative to repo root). */
export function runFile(filePath: string, scriptArgs: string[] = []): RunResult {
	requireBinary();
	const result = spawnSync([ENTRY, "run", filePath, ...scriptArgs], {
		cwd: ROOT,
	});
	const stdout = result.stdout.toString();
	const stderr = result.stderr.toString();
	const allLines = stdout.split(/\r?\n/);
	while (allLines.length > 0 && allLines[allLines.length - 1] === "") {
		allLines.pop();
	}
	return {
		stdout,
		stderr,
		exitCode: result.exitCode ?? 1,
		lines: allLines,
	};
}

/** Compile and run inline source with trailing script argv (`os.args()[1..]`). */
export function runSourceWithArgs(source: string, scriptArgs: string[]): RunResult {
	requireBinary();
	const tmp = path.join(
		os.tmpdir(),
		`llts_test_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
	);
	fs.writeFileSync(tmp, ensureMain(source), "utf-8");
	try {
		return runFile(tmp, scriptArgs);
	} finally {
		fs.unlinkSync(tmp);
	}
}

/** Assert the run succeeded (exit 0) and produced exactly the expected output lines. */
export function expectOutput(result: RunResult, expected: string[]) {
	if (result.exitCode !== 0) {
		throw new Error(
			`Expected exit 0, got ${result.exitCode}.\nstderr: ${result.stderr}\nstdout: ${result.stdout}`,
		);
	}
	for (let i = 0; i < expected.length; i++) {
		const line = result.lines[i];
		const want = expected[i];
		if (line !== want) {
			throw new Error(
				`Output line ${i + 1} mismatch:\n  expected: ${JSON.stringify(want)}\n  got:      ${JSON.stringify(line)}\nFull output:\n${result.stdout}`,
			);
		}
	}
}

/** Assert the run failed (non-zero exit) and stderr/stdout contains the given message. */
export function expectError(result: RunResult, containing: string) {
	if (result.exitCode === 0) {
		throw new Error(
			`Expected a non-zero exit but process succeeded.\nstdout: ${result.stdout}`,
		);
	}
	const combined = result.stderr + result.stdout;
	if (!combined.includes(containing)) {
		throw new Error(
			`Expected error containing ${JSON.stringify(containing)}\nbut got:\n${combined}`,
		);
	}
}
