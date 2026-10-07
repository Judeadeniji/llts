/**
 * Phase 4.3: Explicit integer overflow semantics.
 *
 * Plain `+`/`-`/`*` are checked: an overflow traps with a deterministic
 * diagnostic. The wrapping operators `+%`/`-%`/`*%` opt into two's-complement
 * wraparound. Constant expressions are checked at compile time too.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// --- width-typed overflow traps -------------------------------------------

test("checked u8 addition overflows and traps", () => {
	expectError(
		runSource(`
$b: u8 = 250;
$c = b + 10;
print(c);
`),
		"integer overflow",
	);
});

test("wrapping u8 addition wraps to two's complement", () => {
	expectOutput(
		runSource(`
$b: u8 = 250;
$c = b +% 10;
print(c);
`),
		["4"],
	);
});

test("checked i32 multiplication overflows and traps", () => {
	expectError(
		runSource(`
$x: i32 = 2000000000;
print(x * x);
`),
		"integer overflow",
	);
});

test("wrapping i32 multiplication wraps", () => {
	expectOutput(
		runSource(`
$x: i32 = 2000000000;
print(x *% x);
`),
		["-1651507200"],
	);
});

test("checked u8 subtraction traps below zero", () => {
	expectError(
		runSource(`
$b: u8 = 3;
$c = b - 5;
print(c);
`),
		"integer overflow",
	);
});

test("wrapping u8 subtraction wraps", () => {
	expectOutput(
		runSource(`
$b: u8 = 3;
$c = b -% 5;
print(c);
`),
		["254"],
	);
});

// --- untyped i64 overflow --------------------------------------------------

test("checked i64 addition traps at the limit", () => {
	expectError(
		runSource(`
$a = 9223372036854775807;
print(a + 1);
`),
		"integer overflow",
	);
});

test("wrapping i64 addition wraps at the limit", () => {
	expectOutput(
		runSource(`
$a = 9223372036854775807;
print(a +% 1);
`),
		["-9223372036854775808"],
	);
});

test("in-range checked arithmetic is unaffected", () => {
	expectOutput(
		runSource(`
$a = 40;
$b = 2;
print(a + b);
print(a - b);
print(a * b);
`),
		["42", "38", "80"],
	);
});

// --- compound assignment is checked ---------------------------------------

test("compound += is checked (no silent wraparound)", () => {
	// `b += 10` desugars through an implicit narrowing store back into `u8`,
	// so the out-of-range result is rejected rather than silently wrapping.
	expectError(
		runSource(`
$b: u8 = 250;
b += 10;
print(b);
`),
		"out of range",
	);
});

test("compound += within range works", () => {
	expectOutput(
		runSource(`
$b: u8 = 5;
b += 10;
print(b);
`),
		["15"],
	);
});

// --- constant expressions --------------------------------------------------

test("constant overflow is rejected at compile time", () => {
	expectError(
		runSource(`
@const $a = 9223372036854775807 + 1;
print(a);
`),
		"integer overflow in constant expression",
	);
});

test("wrapping constant expression does not overflow", () => {
	expectOutput(
		runSource(`
@const $a = 9223372036854775807 +% 1;
print(a);
`),
		["-9223372036854775808"],
	);
});
