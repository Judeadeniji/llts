/**
 * Honest `u8`/`byte` + `@as` (Track B step 4).
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("@as widens and narrows between int and u8", () => {
	expectOutput(
		runSource(`
$b: u8 = @as(u8, 42);
print(@typeOf(b));
print(b);
$n: int = @as(int, b);
print(@typeOf(n));
print(n);
`),
		["u8", "42", "i64", "42"],
	);
});

test("byte annotation rejects bare int variable without @as", () => {
	expectError(
		runSource(`
$n: int = 3;
$b: u8 = n;
`),
		"not assignable",
	);
});

test("int annotation rejects bare u8 without @as", () => {
	expectError(
		runSource(`
$b: u8 = @as(u8, 3);
$n: int = b;
`),
		"not assignable",
	);
});

test("integer literal may coerce into u8", () => {
	expectOutput(
		runSource(`
$b: u8 = 7;
print(b);
print(@sizeOf(u8));
print(@sizeOf(byte));
`),
		["7", "1", "1"],
	);
});

test("[]byte index yields u8; store accepts literal", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$buf = @new(a, [3]byte);
buf[0] = 10;
buf[1] = 20;
print(@typeOf(buf[0]));
print(buf[0]);
print(@as(int, buf[1]) + @as(int, buf[0]));
a.deinit();
`),
		["u8", "10", "30"],
	);
});

test("@as(u8) rejects out-of-range at runtime", () => {
	expectError(
		runSource(`
$n: int = 300;
$b: u8 = @as(u8, n);
print(b);
`),
		"out of range",
	);
});
