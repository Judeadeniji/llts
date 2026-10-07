/**
 * Phase 4.4: Safe array & slice indexing.
 *
 * - Fixed-size `[N]T` with a constant index is bounds-checked at compile time.
 * - Dynamic indices keep the runtime bounds trap.
 * - `arr.get(i)` returns `?T`, yielding `null` instead of trapping.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// --- compile-time constant bounds -----------------------------------------

test("constant index past a fixed array is a compile error", () => {
	expectError(
		runSource(`
$a: [3]int = [1, 2, 3];
print(a[5]);
`),
		"out of bounds for fixed-size array",
	);
});

test("negative constant index is a compile error", () => {
	expectError(
		runSource(`
$a: [3]int = [1, 2, 3];
print(a[0 - 1]);
`),
		"out of bounds for fixed-size array",
	);
});

test("index equal to length is a compile error", () => {
	expectError(
		runSource(`
$a: [3]int = [1, 2, 3];
print(a[3]);
`),
		"out of bounds for fixed-size array",
	);
});

test("in-bounds constant index compiles and runs", () => {
	expectOutput(
		runSource(`
$a: [3]int = [1, 2, 3];
print(a[0]);
print(a[2]);
`),
		["1", "3"],
	);
});

test("@const index folds into the compile-time bounds check", () => {
	expectOutput(
		runSource(`
@const $N = 1;
$a: [3]int = [1, 2, 3];
print(a[N]);
`),
		["2"],
	);
});

// --- dynamic indices keep the runtime trap --------------------------------

test("dynamic index out of bounds still traps at runtime", () => {
	expectError(
		runSource(`
$a = [1, 2, 3];
$i = 7;
print(a[i]);
`),
		"Array index out of bounds",
	);
});

// --- arr.get(i): ?T -------------------------------------------------------

test("arr.get returns the element when in bounds", () => {
	expectOutput(
		runSource(`
$a = [10, 20, 30];
@if (a.get(1)) |v| { print(v); } @else { print("none"); }
`),
		["20"],
	);
});

test("arr.get returns null when out of bounds", () => {
	expectOutput(
		runSource(`
$a = [10, 20, 30];
@if (a.get(9)) |v| { print(v); } @else { print("none"); }
`),
		["none"],
	);
});

test("arr.get on a string yields ?byte", () => {
	expectOutput(
		runSource(`
$s = "hi";
@if (s.get(1)) |c| { print(c); } @else { print("none"); }
@if (s.get(9)) |c| { print(c); } @else { print("none"); }
`),
		["105", "none"],
	);
});

test("strict: arr.get(i) is typed as ?T", () => {
	expectOutput(
		runSource(`
$a: [3]int = [1, 2, 3];
$v = a.get(0);
@if (v) |x| { print(x); } @else { print("none"); }
`),
		["1"],
	);
});
