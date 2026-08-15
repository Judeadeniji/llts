/**
 * Honest f32/f64 + language slice views `arr[i..j]`.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("f32 and f64 are distinct types", () => {
	expectOutput(
		runSource(`
$a: f64 = 1.5;
$b: f32 = 2.5;
print(@typeOf(a));
print(@typeOf(b));
print(@sizeOf(f64));
print(@sizeOf(f32));
print(a);
print(b);
`),
		["f64", "f32", "8", "4", "1.5", "2.5"],
	);
});

test("@as converts between int and float widths", () => {
	expectOutput(
		runSource(`
$n: int = 3;
$f: f64 = @as(f64, n);
$s: f32 = @as(f32, f);
print(@typeOf(f));
print(@typeOf(s));
print(@as(int, s));
`),
		["f64", "f32", "3"],
	);
});

test("mixed f32/f64 arithmetic requires @as", () => {
	expectError(
		runSource(`
$a: f64 = 1.0;
$b: f32 = 2.0;
print(a + b);
`),
		"use @as",
	);
});

test("arr[i..j] slices []byte", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$buf = @new(a, [5]byte);
buf[0] = 10;
buf[1] = 20;
buf[2] = 30;
buf[3] = 40;
buf[4] = 50;
$mid = buf[1..4];
print(len(mid));
print(mid[0]);
print(mid[2]);
print(@typeOf(mid));
a.deinit();
`),
		["3", "20", "40", "[]byte"],
	);
});

test("string[i..j] yields a string view", () => {
	expectOutput(
		runSource(`
$s = "hello";
$t = s[1..4];
print(t);
print(len(t));
`),
		["ell", "3"],
	);
});

test("slice out of bounds is a runtime error", () => {
	expectError(
		runSource(`
$s = "hi";
print(s[0..5]);
`),
		"Slice out of bounds",
	);
});
