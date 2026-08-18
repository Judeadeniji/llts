/**
 * LLTS test helpers — spawn the Zig `llts` binary so suite cases stay
 * language-level (Bun is only the test runner).
 *
 * Set LLTS_TEST_LLVM=1 to run every test through both the bytecode VM and
 * the LLVM backend, asserting matching output for parity coverage.
 */
import { spawnSync } from "bun";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";
import { execSync } from "node:child_process";

const ROOT = path.resolve(import.meta.dir, "..");
const ENTRY = path.join(ROOT, "zig-out/bin/llts");
const TEST_LLVM = process.env.LLTS_TEST_LLVM === "1";

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
	const vmResult: RunResult = {
		stdout,
		stderr,
		exitCode: result.exitCode ?? 1,
		lines: allLines,
	};

	if (TEST_LLVM) {
		const llvmResult = runFileLlvm(filePath, scriptArgs);
		assertParity(vmResult, llvmResult, filePath);
	}

	return vmResult;
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

// ─── LLVM backend ────────────────────────────────────────────────────────

let _clang: string | null = null;
function findClang(): string {
	if (_clang) return _clang;
	for (const c of ["clang-21", "clang"]) {
		try {
			execSync(`which ${c}`, { stdio: "pipe" });
			_clang = c;
			return c;
		} catch {}
	}
	throw new Error("need clang or clang-21 to link LLVM bitcode");
}

/** Compile and run a .lls file through the LLVM backend. */
function runFileLlvm(filePath: string, scriptArgs: string[] = []): RunResult {
	requireBinary();
	const absPath = path.isAbsolute(filePath) ? filePath : path.join(ROOT, filePath);
	const base = path.basename(absPath, ".lls");
	const outDir = path.join(ROOT, ".zig-cache", "llvm-emit");
	fs.mkdirSync(outDir, { recursive: true });
	const bc = path.join(outDir, `${base}_${Date.now()}.bc`);
	const exe = path.join(outDir, `${base}_${Date.now()}`);

	try {
		// Emit bitcode
		const emitResult = spawnSync([ENTRY, "emit", absPath, "-o", bc], { cwd: ROOT });
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
			const args = scriptArgs.length > 0 ? ` "${scriptArgs.join('" "')}"` : "";
			const output = execSync(`"${exe}"${args}`, { cwd: ROOT, stdio: "pipe" }).toString();
			const lines = output.split(/\r?\n/);
			while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
			return { stdout: output, stderr: "", exitCode: 0, lines };
		} catch (e: any) {
			const stdout = e.stdout?.toString() ?? "";
			const stderr = e.stderr?.toString() ?? "";
			const lines = stdout.split(/\r?\n/);
			while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
			return { stdout, stderr, exitCode: e.status ?? 1, lines };
		}
	} finally {
		try { fs.unlinkSync(bc); } catch {}
		try { fs.unlinkSync(exe); } catch {}
	}
}

/** Assert VM and LLVM outputs match (trailing-space tolerant). */
function assertParity(vm: RunResult, llvm: RunResult, label: string) {
	// Both must agree on success/failure
	if (vm.exitCode !== llvm.exitCode) {
		throw new Error(
			`[${label}] VM exit ${vm.exitCode} vs LLVM exit ${llvm.exitCode}\nVM stderr: ${vm.stderr.slice(0, 500)}\nLLVM stderr: ${llvm.stderr.slice(0, 500)}`,
		);
	}
	// If both failed, that's fine — error messages may differ
	if (vm.exitCode !== 0) return;
	// Compare output lines (trim trailing whitespace from LLVM printf formatting)
	const vmLines = vm.lines;
	const llvmLines = llvm.lines.map((l) => l.trimEnd());
	if (vmLines.length !== llvmLines.length) {
		throw new Error(
			`[${label}] VM has ${vmLines.length} lines, LLVM has ${llvmLines.length} lines\nVM:    ${JSON.stringify(vmLines)}\nLLVM:  ${JSON.stringify(llvmLines)}`,
		);
	}
	for (let i = 0; i < vmLines.length; i++) {
		if (vmLines[i] !== llvmLines[i]) {
			throw new Error(
				`[${label}] Line ${i + 1} mismatch:\n  VM:    ${JSON.stringify(vmLines[i])}\n  LLVM:  ${JSON.stringify(llvmLines[i])}`,
			);
		}
	}
}

// ─── assertions ──────────────────────────────────────────────────────────

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
