/**
 * Host + LLTS leveled logging via stderr (posix sink).
 */
import { test } from "bun:test";
import { expectOutput, runSource } from "./helpers";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";
import { spawnSync } from "bun";

const ROOT = path.resolve(import.meta.dir, "..");
const ENTRY = path.join(ROOT, "zig-out/bin/llts");

function runWithEnv(source: string, env: Record<string, string | undefined>) {
	const tmp = path.join(
		os.tmpdir(),
		`llts_log_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
	);
	fs.writeFileSync(tmp, source, "utf-8");
	try {
		const merged: Record<string, string> = {};
		for (const [k, v] of Object.entries({ ...process.env, ...env })) {
			if (v !== undefined && v !== "") merged[k] = v;
		}
		// Explicit empty string means delete (for clearing NO_COLOR)
		for (const [k, v] of Object.entries(env)) {
			if (v === "") delete merged[k];
		}
		const result = spawnSync([ENTRY, "-i", tmp], {
			cwd: ROOT,
			env: merged,
		});
		return {
			stdout: result.stdout.toString(),
			stderr: result.stderr.toString(),
			exitCode: result.exitCode ?? 1,
		};
	} finally {
		fs.unlinkSync(tmp);
	}
}

test("debug.info / warn / err appear on stderr with level prefix", () => {
	const res = runWithEnv(
		`
@const $debug = @import("std/debug");
@func main() {
    debug.info("hello-info");
    debug.warn("hello-warn");
    debug.err("hello-err");
}
`,
		{ LLTS_LOG_LEVEL: "info", NO_COLOR: "1" },
	);
	if (res.exitCode !== 0) {
		throw new Error(`exit ${res.exitCode}\nstderr: ${res.stderr}\nstdout: ${res.stdout}`);
	}
	if (!res.stderr.includes("INFO: hello-info")) {
		throw new Error(`missing INFO line:\n${res.stderr}`);
	}
	if (!res.stderr.includes("WARN: hello-warn")) {
		throw new Error(`missing WARN line:\n${res.stderr}`);
	}
	if (!res.stderr.includes("ERROR: hello-err")) {
		throw new Error(`missing ERROR line:\n${res.stderr}`);
	}
});

test("LLTS_LOG_LEVEL=warn suppresses info", () => {
	const res = runWithEnv(
		`
@const $debug = @import("std/debug");
@func main() {
    debug.info("should-hide");
    debug.warn("should-show");
}
`,
		{ LLTS_LOG_LEVEL: "warn", NO_COLOR: "1" },
	);
	if (res.exitCode !== 0) {
		throw new Error(`exit ${res.exitCode}\nstderr: ${res.stderr}`);
	}
	if (res.stderr.includes("should-hide")) {
		throw new Error(`info not filtered:\n${res.stderr}`);
	}
	if (!res.stderr.includes("WARN: should-show")) {
		throw new Error(`missing warn:\n${res.stderr}`);
	}
});

test("debug.assert returns AssertFailed error value", () => {
	expectOutput(
		runSource(`
@const $debug = @import("std/debug");
@func main() {
    $ok = debug.assert(true);
    print(@isError(ok));
    $bad = debug.assert(false);
    print(@isError(bad));
    print(bad.code);
}
`),
		["false", "true", "AssertFailed"],
	);
});

test("FORCE_COLOR embeds ANSI; NO_COLOR does not", () => {
	const src = `
@func main() {
    print(1 / 0);
}
`;
	const forced = runWithEnv(src, { FORCE_COLOR: "1", NO_COLOR: "" });
	if (forced.exitCode === 0) throw new Error("expected failure");
	if (!forced.stderr.includes("\x1b[")) {
		throw new Error(`expected ANSI escapes with FORCE_COLOR:\n${JSON.stringify(forced.stderr)}`);
	}

	const plain = runWithEnv(src, { NO_COLOR: "1", FORCE_COLOR: "0" });
	if (plain.exitCode === 0) throw new Error("expected failure");
	if (plain.stderr.includes("\x1b[")) {
		throw new Error(`unexpected ANSI with NO_COLOR:\n${JSON.stringify(plain.stderr)}`);
	}
});

test("debug.err auto-detects error values", () => {
	const res = runWithEnv(
		`
@const $debug = @import("std/debug");
@func main() {
    debug.err(error("boom"));
    debug.err(error("FileNotFound", "missing.txt"));
    debug.err("plain string");
}
`,
		{ LLTS_LOG_LEVEL: "error", NO_COLOR: "1" },
	);
	if (res.exitCode !== 0) {
		throw new Error(`exit ${res.exitCode}\nstderr: ${res.stderr}`);
	}
	if (!res.stderr.includes("ERROR: boom")) {
		throw new Error(`expected code without Error: prefix:\n${res.stderr}`);
	}
	if (res.stderr.includes("Error: boom")) {
		throw new Error(`redundant Error: prefix:\n${res.stderr}`);
	}
	if (!res.stderr.includes("ERROR: FileNotFound") || !res.stderr.includes("payload: missing.txt")) {
		throw new Error(`expected code + payload lines:\n${res.stderr}`);
	}
	if (!res.stderr.includes("ERROR: plain string")) {
		throw new Error(`expected plain string path:\n${res.stderr}`);
	}
});
