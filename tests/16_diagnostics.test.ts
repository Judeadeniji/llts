/**
 * Runtime diagnostics: stderr source context + LLTS call stacks.
 */
import { test } from "bun:test";
import { expectError, runSource } from "./helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "bun";

const ROOT = path.resolve(import.meta.dir, "..");
const ENTRY = path.join(ROOT, "zig-out/bin/llts");

test("runtime error prints source context on stderr", () => {
	const res = runSource(`
pub @func main() {
    @const $a = [1, 2];
    print(a[9]);
}
`);
	expectError(res, "out of bounds");
	if (!res.stderr.includes("Error:")) {
		throw new Error(`expected Error: on stderr, got:\n${res.stderr}`);
	}
	// Must not dump a Node/JS stack from the host by default
	if (res.stderr.includes("at execute (") || res.stderr.includes("vm/execute.ts")) {
		throw new Error(`unexpected JS stack on stderr:\n${res.stderr}`);
	}
	// No duplicate Zig error name after rich report
	if (res.stderr.includes("Error: RuntimeError")) {
		throw new Error(`duplicate Error: RuntimeError on stderr:\n${res.stderr}`);
	}
});

test("runtime error prints LLTS call stack", () => {
	const res = runSource(`
@func boom() {
    @const $a = [1];
    print(a[5]);
}

@func mid() {
    boom();
}

pub @func main() {
    mid();
}
`);
	expectError(res, "out of bounds");
	const err = res.stderr;
	if (!err.includes("at boom (")) {
		throw new Error(`missing boom frame:\n${err}`);
	}
	if (!err.includes("at mid (")) {
		throw new Error(`missing mid frame:\n${err}`);
	}
	if (!err.includes("at main (")) {
		throw new Error(`missing main frame:\n${err}`);
	}
});

test("non-heap runtime fail also has rich diagnostics", () => {
	const res = runSource(`
pub @func main() {
    print(1 / 0);
}
`);
	expectError(res, "Division by zero");
	if (!res.stderr.includes("Error:")) {
		throw new Error(`expected Error: on stderr, got:\n${res.stderr}`);
	}
	if (!res.stderr.includes("--> ")) {
		throw new Error(`expected source pointer on stderr, got:\n${res.stderr}`);
	}
	if (res.stderr.includes("Error: RuntimeError")) {
		throw new Error(`duplicate Error: RuntimeError:\n${res.stderr}`);
	}
});

test("runtime caret uses non-1 column for mid-line fault", () => {
	// Spaces before print so the OOB index expression sits past column 1
	const res = runSource(`pub @func main() {
    @const $a = [1];
      print(a[9]);
}
`);
	expectError(res, "out of bounds");
	const m = res.stderr.match(/--> [^:]+:(\d+):(\d+)/);
	if (!m) throw new Error(`missing --> location:\n${res.stderr}`);
	const col = Number(m[2]);
	if (!(col > 1)) {
		throw new Error(`expected column > 1, got ${col}:\n${res.stderr}`);
	}
});

test("cross-module stack frames show imported file path", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_diag_"));
	const helper = path.join(dir, "helper.lls");
	const main = path.join(dir, "main.lls");
	fs.writeFileSync(
		helper,
		`pub @func boom() {
    @const $a = [1];
    print(a[9]);
}
`,
		"utf-8",
	);
	fs.writeFileSync(
		main,
		`@const $h = @import("./helper.lls");
pub @func main() {
    h.boom();
}
`,
		"utf-8",
	);
	try {
		const result = spawnSync([ENTRY, "run", main], { cwd: ROOT });
		const stderr = result.stderr.toString();
		if ((result.exitCode ?? 1) === 0) {
			throw new Error(`expected failure, got success\n${stderr}`);
		}
		if (!stderr.includes("helper.lls")) {
			throw new Error(`expected helper.lls in stack/report:\n${stderr}`);
		}
		if (!stderr.includes("at ") || !stderr.includes("boom")) {
			throw new Error(`missing boom frame:\n${stderr}`);
		}
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

test("syntax error prints source context and location frame", () => {
	const res = runSource(`@const err = error("x");`);
	expectError(res, "Expected $RegisterName");
	if (!res.stderr.includes("Error:")) {
		throw new Error(`expected Error: on stderr, got:\n${res.stderr}`);
	}
	if (!res.stderr.includes("--> ")) {
		throw new Error(`expected source pointer on stderr, got:\n${res.stderr}`);
	}
	if (!res.stderr.includes("at <parse> (")) {
		throw new Error(`missing location frame:\n${res.stderr}`);
	}
	if (res.stderr.includes("parser/index.ts") || res.stderr.includes("at consume (")) {
		throw new Error(`unexpected JS stack on stderr:\n${res.stderr}`);
	}
});

test("compile error prints to stderr without JS dump", () => {
	const res = runSource(`
$x: int = "no";
`);
	expectError(res, "not assignable");
	if (res.stderr.includes("at typecheck (") || res.stderr.includes("typecheck.ts")) {
		throw new Error(`unexpected JS stack on stderr:\n${res.stderr}`);
	}
	if (!res.stderr.includes("at <compile> (")) {
		throw new Error(`missing compile stack frame:\n${res.stderr}`);
	}
	if (!res.stderr.includes("--> ")) {
		throw new Error(`expected source pointer on compile error:\n${res.stderr}`);
	}
});

test("scanner error prints source context and stack frame", () => {
	const res = runSource(`$x = @;`);
	expectError(res, "Expected compiler keyword");
	if (!res.stderr.includes("--> ")) {
		throw new Error(`expected source pointer:\n${res.stderr}`);
	}
	if (!res.stderr.includes("at <scan> (")) {
		throw new Error(`missing scan stack frame:\n${res.stderr}`);
	}
});

test("import of broken module prints import chain", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_imp_"));
	const bad = path.join(dir, "bad.lls");
	const main = path.join(dir, "main.lls");
	fs.writeFileSync(bad, `$x = @;\n`, "utf-8");
	fs.writeFileSync(
		main,
		`@const $b = @import("./bad.lls");
pub @func main() { print(1); }
`,
		"utf-8",
	);
	try {
		const result = spawnSync([ENTRY, "run", main], { cwd: ROOT });
		const stderr = result.stderr.toString();
		if ((result.exitCode ?? 1) === 0) {
			throw new Error(`expected failure\n${stderr}`);
		}
		if (!stderr.includes("at <scan> (")) {
			throw new Error(`missing scan frame:\n${stderr}`);
		}
		if (!stderr.includes('@import("./bad.lls")') && !stderr.includes("@import(")) {
			throw new Error(`missing import frame:\n${stderr}`);
		}
		if (!stderr.includes("main.lls")) {
			throw new Error(`expected importer path in stack:\n${stderr}`);
		}
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

test("nested import scan error prints full import chain", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_imp_nest_"));
	const bad = path.join(dir, "bad.lls");
	const mid = path.join(dir, "mid.lls");
	const main = path.join(dir, "main.lls");
	fs.writeFileSync(bad, `$x = @;\n`, "utf-8");
	fs.writeFileSync(
		mid,
		`@const $b = @import("./bad.lls");
pub @func ok() { return 1; }
`,
		"utf-8",
	);
	fs.writeFileSync(
		main,
		`@const $m = @import("./mid.lls");
pub @func main() { print(m.ok()); }
`,
		"utf-8",
	);
	try {
		const result = spawnSync([ENTRY, "run", main], { cwd: ROOT });
		const stderr = result.stderr.toString();
		if ((result.exitCode ?? 1) === 0) throw new Error(`expected failure\n${stderr}`);
		if (!stderr.includes("at <scan> (")) throw new Error(`missing scan frame:\n${stderr}`);
		if (!stderr.includes('@import("./bad.lls")')) throw new Error(`missing mid→bad import:\n${stderr}`);
		if (!stderr.includes('@import("./mid.lls")')) throw new Error(`missing main→mid import:\n${stderr}`);
		if (!stderr.includes("main.lls")) throw new Error(`missing main.lls:\n${stderr}`);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

test("import parse error prints import chain", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_imp_parse_"));
	const bad = path.join(dir, "bad.lls");
	const main = path.join(dir, "main.lls");
	fs.writeFileSync(bad, `$x = (;\n`, "utf-8");
	fs.writeFileSync(
		main,
		`@const $b = @import("./bad.lls");
pub @func main() { print(1); }
`,
		"utf-8",
	);
	try {
		const result = spawnSync([ENTRY, "run", main], { cwd: ROOT });
		const stderr = result.stderr.toString();
		if ((result.exitCode ?? 1) === 0) throw new Error(`expected failure\n${stderr}`);
		if (!stderr.includes("Unexpected token in expression")) throw new Error(`wrong message:\n${stderr}`);
		if (!stderr.includes("at <parse> (")) throw new Error(`missing parse frame:\n${stderr}`);
		if (!stderr.includes('@import("./bad.lls")')) throw new Error(`missing import frame:\n${stderr}`);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

test("import compile error prints import chain", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_imp_comp_"));
	const bad = path.join(dir, "bad.lls");
	const mid = path.join(dir, "mid.lls");
	const main = path.join(dir, "main.lls");
	fs.writeFileSync(
		bad,
		`pub @func boom() {
    print(unknown_thing);
}
`,
		"utf-8",
	);
	fs.writeFileSync(
		mid,
		`@const $b = @import("./bad.lls");
pub @func go() { b.boom(); }
`,
		"utf-8",
	);
	fs.writeFileSync(
		main,
		`@const $m = @import("./mid.lls");
pub @func main() { m.go(); }
`,
		"utf-8",
	);
	try {
		const result = spawnSync([ENTRY, "run", main], { cwd: ROOT });
		const stderr = result.stderr.toString();
		if ((result.exitCode ?? 1) === 0) throw new Error(`expected failure\n${stderr}`);
		if (!stderr.includes("Unknown identifier")) throw new Error(`wrong message:\n${stderr}`);
		if (!stderr.includes("at <compile> (")) throw new Error(`missing compile frame:\n${stderr}`);
		if (!stderr.includes('@import("./bad.lls")')) throw new Error(`missing mid→bad import:\n${stderr}`);
		if (!stderr.includes('@import("./mid.lls")')) throw new Error(`missing main→mid import:\n${stderr}`);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});
