/**
 * `*T` / `?*T` pointers — heap handles with honest types.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("@typeOf(@new(a, Point)) is *Point", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: i64; y: i64; }
$a = mem.create(0);
$p = @new(a, Point);
print(@typeOf(p));
print(p.x);
a.deinit();
`),
		["*Point", "0"],
	);
});

test("*Point is not assignable to Point without being the same kind", () => {
	expectError(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: i64; }
$a = mem.create(0);
$p: Point = @new(a, Point);
print(p.x);
`),
		"not assignable",
	);
});

test("?*T accepts null and *T", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Box { n: i64; }
$a = mem.create(0);
$p: ?*Box = null;
print(@typeOf(p));
p = @new(a, Box { n: 9 });
print(@typeOf(p));
print(p.n);
a.deinit();
`),
		["?*Box", "?*Box", "9"],
	);
});

test("@sizeOf(*T) is handle-sized", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; y: i64; }
print(@sizeOf(*Point));
print(@sizeOf(?*Point));
`),
		["8", "8"],
	);
});

test("&struct_value yields *T and shares the handle", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; y: i64; }
$p = Point { x: 1, y: 2 };
$q: *Point = &p;
print(@typeOf(q));
print(q.x);
q.x = 9;
print(p.x);
`),
		["*Point", "1", "9"],
	);
});

test("& rejects scalars", () => {
	expectError(
		runSource(`
$n: i64 = 1;
$p = &n;
print(p);
`),
		"address-of requires a struct value",
	);
});

test("& rejects already-pointers", () => {
	expectError(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: i64; }
$a = mem.create(0);
$p = @new(a, Point);
$q = &p;
print(q);
`),
		"cannot take address of a pointer",
	);
});

test("returning &frame_struct is still an escape error", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
@func bad(): *Point {
    $p = Point { x: 1 };
    return &p;
}
print(bad());
`),
		"escapes its frame region",
	);
});

test("bitwise AND still parses beside unary &", () => {
	expectOutput(
		runSource(`
print(6 & 3);
@struct Point { x: i64; }
$p = Point { x: 1 };
$q = &p;
print(q.x);
`),
		["2", "1"],
	);
});
