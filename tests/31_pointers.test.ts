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
