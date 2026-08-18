/**
 * LLTS test helpers — spawn the Zig `llts` binary so suite cases stay
 * language-level (Bun is only the test runner).
 */
import { spawnSync } from "bun";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";
import { execSync } from "node:child_process";

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

/** Find clang-21 or clang on PATH. */
function findClang(): string {
	for (const c of ["clang-21", "clang"]) {
		try {
			execSync(`which ${c}`, { stdio: "pipe" });
			return c;
		} catch {}
	}
	throw new Error("need clang or clang-21 to link LLVM bitcode");
}

/** Compile and run inline source through the LLVM backend. */
export function runSourceLlvm(source: string): RunResult {
	requireBinary();
	const tmp = path.join(
		os.tmpdir(),
		`llts_test_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
	);
	const exe = tmp.replace(/\.lls$/, "")
	const bc = tmp.replace(/\.lls$/, ".bc")
	fs.writeFileSync(tmp, ensureMain(source), "utf-8");
	try {
		// Emit bitcode
		const emitResult = spawnSync([ENTRY, "emit", tmp, "-o", bc], {
			cwd: ROOT,
		});
		if (emitResult.exitCode !== 0) {
			return {
				stdout: "",
				stderr: emitResult.stderr.toString() + emitResult.stdout.toString(),
				exitCode: emitResult.exitCode ?? 1,
				lines: [],
			};
		}
		// Link with clang
		const clang = findClang();
		const rt = path.join(ROOT, "zig-out/lib/llts-runtime.o");
		const rtNatives = path.join(ROOT, "zig-out/lib/llts-runtime-natives.o");
		try {
			execSync(
				`"${clang}" "${bc}" "${rt}" "${rtNatives}" -o "${exe}" -lm -lcurl -s -Wl,--gc-sections`,
				{ cwd: ROOT, stdio: "pipe" },
			);
		} catch (e: any) {
			return {
				stdout: "",
				stderr: e.stderr?.toString() ?? "",
				exitCode: e.status ?? 1,
				lines: [],
			};
		}
		// Run
		try {
			const output = execSync(`"${exe}"`, { cwd: ROOT, stdio: "pipe" })
				.toString();
			const lines = output.split(/\r?\n/);
			while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
			return { stdout: output, stderr: "", exitCode: 0, lines };
		} catch (e: any) {
			const stdout = e.stdout?.toString() ?? "";
			const stderr = e.stderr?.toString() ?? "";
			const lines = stdout.split(/\r?\n/);
			while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
			return { stdout, stderr, exitCode: e.status ?? 1, lines };
		} finally {
			try { fs.unlinkSync(bc); } catch {}
			try { fs.unlinkSync(exe); } catch {}
		}
	} finally {
		try { fs.unlinkSync(tmp); } catch {}
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
