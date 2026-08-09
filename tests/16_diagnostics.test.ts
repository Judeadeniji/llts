/**
 * Runtime diagnostics: stderr source context + LLTS call stacks.
 */
import { test } from "bun:test";
import { expectError, runSource } from "./helpers";

test("runtime error prints source context on stderr", () => {
	const res = runSource(`
@func main() {
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

@func main() {
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

test("syntax error prints source context and location frame", () => {
	const res = runSource(`@const err = error("x");`);
	expectError(res, "Expected $RegisterName");
	if (!res.stderr.includes("Error:")) {
		throw new Error(`expected Error: on stderr, got:\n${res.stderr}`);
	}
	if (!res.stderr.includes("--> ")) {
		throw new Error(`expected source pointer on stderr, got:\n${res.stderr}`);
	}
	if (!res.stderr.includes("at <script> (")) {
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
});
