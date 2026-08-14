/**
 * @new(allocator, Type) — zero-default allocate sized arrays / structs into an arena.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("@new(a, [N]byte) zeros and has len", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$b = @new(a, [4]byte);
print(len(b));
print(b[0]);
print(b[3]);
b[1] = 9;
print(b[1]);
a.reset();
`),
		["4", "0", "0", "9"],
	);
});

test("@new(a, Point) zeros struct fields", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: int; y: int; }
$a = mem.create(0);
$p = @new(a, Point);
print(p.x);
print(p.y);
p.x = 5;
print(p.x);
a.deinit();
`),
		["0", "0", "5"],
	);
});

test("@new(a, Point) may be returned (Pass region)", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: int; y: int; }
@func make(a): Point {
    $p = @new(a, Point);
    p.x = 1;
    p.y = 2;
    return p;
}
pub @func main() {
    $a = mem.create(0);
    defer a.deinit();
    $p = make(a);
    print(p.x);
    print(p.y);
}
`),
		["1", "2"],
	);
});

test("@new still accepts struct and array literals", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: int; y: int; }
$a = mem.create(0);
$p = @new(a, Point { x: 3, y: 4 });
$arr = @new(a, [1, 2, 3]);
print(p.x);
print(len(arr));
print(arr[2]);
a.deinit();
`),
		["3", "3", "3"],
	);
});

test("@new rejects unsized slice without length", () => {
	expectError(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$b = @new(a, []byte);
`),
		"length",
	);
});

test("@new(a, []byte, n) runtime length", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$n = 5;
$b = @new(a, []byte, n);
print(len(b));
print(b[0]);
b[4] = 42;
print(b[4]);
a.reset();
`),
		["5", "0", "42"],
	);
});

test("@new(a, string, n) makes a byte buffer", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$s = @new(a, string, 3);
print(len(s));
s[0] = 65;
s[1] = 66;
s[2] = 67;
print(s[0]);
print(s[2]);
a.deinit();
`),
		["3", "65", "67"],
	);
});
