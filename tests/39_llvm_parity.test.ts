/**
 * LLVM parity tests — run the same source through both the bytecode VM and
 * the LLVM backend, asserting identical output for each case.
 */
import { describe, test } from "bun:test";
import { runSource, runSourceLlvm, expectOutput } from "./helpers";

/** Run source through both backends and assert outputs match. */
function expectBoth(source: string, expected: string[]) {
	const vm = runSource(source);
	const llvm = runSourceLlvm(source);

	// VM must succeed
	expectOutput(vm, expected);

	// LLVM must succeed with the same output
	if (llvm.exitCode !== 0) {
		throw new Error(
			`LLVM backend failed (exit ${llvm.exitCode}):\nstderr: ${llvm.stderr}\nstdout: ${llvm.stdout}\nVM output: ${JSON.stringify(expected)}`,
		);
	}
	// Trim trailing spaces — LLVM printf adds trailing space on numeric args
	const llvmTrimmed = llvm.lines.map((l) => l.trimEnd());
	for (let i = 0; i < expected.length; i++) {
		const line = llvmTrimmed[i];
		const want = expected[i];
		if (line !== want) {
			throw new Error(
				`Line ${i + 1} mismatch between VM and LLVM:\n  VM:    ${JSON.stringify(vm.lines[i])}\n  LLVM:  ${JSON.stringify(line)}\n  want:  ${JSON.stringify(want)}`,
			);
		}
	}
}

// ─── arithmetic ──────────────────────────────────────────────────────────

describe("llvm parity: arithmetic", () => {
	test("basic math", () => {
		expectBoth("print(2 + 3);\nprint(10 - 4);\nprint(3 * 7);", ["5", "6", "21"]);
	});

	test("comparisons", () => {
		expectBoth("print(5 > 3);\nprint(5 < 3);\nprint(5 == 5);", ["true", "false", "true"]);
	});

	test("boolean logic", () => {
		expectBoth("print(true && false);\nprint(true || false);\nprint(!true);", ["false", "true", "false"]);
	});
});

// ─── string operations ───────────────────────────────────────────────────

describe("llvm parity: strings", () => {
	test("len, indexOf, substr", () => {
		expectBoth(
			'@const $string = @import("std/string");\n@const $s = "hello world";\nprint(len(s));\nprint(string.indexOf(s, "world"));\nprint(string.substr(s, 0, 5));',
			["11", "6", "hello"],
		);
	});

	test("split", () => {
		expectBoth(
			'@const $string = @import("std/string");\n$parts = string.split("a,b,c", ",");\nprint(len(parts));\nprint(parts[0]);\nprint(parts[1]);\nprint(parts[2]);',
			["3", "a", "b", "c"],
		);
	});

	test("contains", () => {
		expectBoth(
			'@const $string = @import("std/string");\nprint(string.contains("hello world", "world"));\nprint(string.contains("hello", "xyz"));',
			["true", "false"],
		);
	});
});

// ─── math ────────────────────────────────────────────────────────────────

describe("llvm parity: math", () => {
	test("floor", () => {
		expectBoth(
			'@const $math = @import("std/math");\nprint(math.floor(3.7));',
			["3"],
		);
	});

	test("min and max", () => {
		expectBoth(
			'@const $math = @import("std/math");\nprint(math.min(3, 7));\nprint(math.max(3, 7));',
			["3", "7"],
		);
	});
});

// ─── control flow ────────────────────────────────────────────────────────

describe("llvm parity: control flow", () => {
	test("if/else", () => {
		expectBoth(
			'$x = 10;\n@if (x > 5) {\n    print("big");\n} @else {\n    print("small");\n}',
			["big"],
		);
	});

	test("for range", () => {
		expectBoth(
			'@for (0..3) |i| {\n    print(i);\n}',
			["0", "1", "2"],
		);
	});

	test("switch", () => {
		expectBoth(
			'$x = 2;\n@switch (x) {\n    1 => { print("one"); }\n    2 => { print("two"); }\n    3 => { print("three"); }\n}',
			["two"],
		);
	});
});

// ─── functions ───────────────────────────────────────────────────────────

describe("llvm parity: functions", () => {
	test("function call and return", () => {
		expectBoth(
			'@func add(a, b) {\n    return a + b;\n}\nprint(add(3, 4));',
			["7"],
		);
	});
});

// ─── len / arrays ────────────────────────────────────────────────────────

describe("llvm parity: arrays", () => {
	test("fixed array", () => {
		expectBoth(
			'$a = [10, 20, 30];\nprint(len(a));\nprint(a[1]);',
			["3", "20"],
		);
	});
});

// ─── globals ─────────────────────────────────────────────────────────────

describe("llvm parity: globals", () => {
	test("const and var globals", () => {
		expectBoth(
			'@const $x = 42;\n$y = 10;\nprint(x);\nprint(y);',
			["42", "10"],
		);
	});
});
