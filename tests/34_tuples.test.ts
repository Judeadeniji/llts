/**
 * Tuple types `[T, U, …]` — distinct from homogeneous arrays.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("heterogeneous literal is a tuple", () => {
	expectOutput(
		runSource(`
$p = [1, "hi"];
print(@typeOf(p));
print(p[0]);
print(p[1]);
print(p.0);
print(p.1);
`),
		["[i64, [2]byte]", "1", "hi", "1", "hi"],
	);
});

test("@type Pair = [i64, string] with annotation", () => {
	expectOutput(
		runSource(`
@type Pair = [i64, string];
$p: Pair = [7, "x"];
print(@typeOf(p));
print(p.0);
print(p.1);
print(@sizeOf(Pair));
`),
		["Pair", "7", "x", "8"],
	);
});

test("homogeneous literal stays an array", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
print(@typeOf(a));
print(a[1]);
`),
		["[3]i64", "2"],
	);
});

test("tuple index out of range is an error", () => {
	expectError(
		runSource(`
$p: [i64, string] = [1, "a"];
print(p[2]);
`),
		"out of range",
	);
});

test("cannot assign wrong element type into tuple slot", () => {
	expectError(
		runSource(`
$p: [i64, string] = [1, "a"];
p.0 = "nope";
`),
		"not assignable",
	);
});

test("tuple assign and update via .N", () => {
	expectOutput(
		runSource(`
$p: [i64, string] = [1, "a"];
p.0 = 9;
p[1] = "b";
print(p.0);
print(p.1);
`),
		["9", "b"],
	);
});
