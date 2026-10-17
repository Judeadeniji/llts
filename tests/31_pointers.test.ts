/**
 * Exhaustive `*T` / `?*T` / `&` coverage.
 *
 * Model: pointers are type-level aliases of aggregate handles (runtime identity).
 * Value assign copies aggregates; `*T` assign / `&x` share. No `**T`, no `&scalar`.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// ---------------------------------------------------------------------------
// @new → *T
// ---------------------------------------------------------------------------

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

test("function returning @new is *T not T", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: i64; y: i64; }
@func mk(arena) {
    $p = @new(arena, Point);
    p.x = 1;
    p.y = 2;
    return p;
}
$a = mem.create(0);
$p = mk(a);
print(@typeOf(p));
print(p.x);
a.deinit();
`),
		["*Point", "1"],
	);
});

test("@new([N]byte) yields *[N]byte", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$a = mem.create(0);
$buf = @new(a, [4]byte);
print(@typeOf(buf));
buf[0] = 7;
print(buf[0]);
a.deinit();
`),
		["*[4]byte", "7"],
	);
});

// ---------------------------------------------------------------------------
// Assignability
// ---------------------------------------------------------------------------

test("*Point is not assignable to Point", () => {
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

test("Point is not assignable to *Point", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$v = Point { x: 1 };
$p: *Point = v;
print(p.x);
`),
		"not assignable",
	);
});

test("*[3]i64 is not assignable to [3]i64", () => {
	expectError(
		runSource(`
$a = [1, 2, 3];
$p = &a;
$b: [3]i64 = p;
print(b[0]);
`),
		"not assignable",
	);
});

test("*T is assignable to ?*T", () => {
	expectOutput(
		runSource(`
@struct Box { n: i64; }
$v = Box { n: 3 };
$p: *Box = &v;
$o: ?*Box = p;
print(@typeOf(o));
print(o.n);
`),
		["?*Box", "3"],
	);
});

// ---------------------------------------------------------------------------
// Optional pointers
// ---------------------------------------------------------------------------

test("?*T accepts null and *T", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Box { n: i64; }
$a = mem.create(0);
$p: ?*Box = null;
print(@typeOf(p));
$bx = @new(a, Box);
bx.n = 9;
p = bx;
print(@typeOf(p));
print(p.n);
a.deinit();
`),
		["?*Box", "?*Box", "9"],
	);
});

test("?*T field access after null assign is null-checkable", () => {
	expectOutput(
		runSource(`
@struct Box { n: i64; }
$v = Box { n: 1 };
$o: ?*Box = &v;
print(o == null);
o = null;
print(o == null);
`),
		["false", "true"],
	);
});

test("?*[N]T index after binding a pointer", () => {
	expectOutput(
		runSource(`
$a = [10, 20, 30];
$o: ?*[3]i64 = &a;
o[1] = 99;
print(a[1]);
`),
		["99"],
	);
});

// ---------------------------------------------------------------------------
// @sizeOf
// ---------------------------------------------------------------------------

test("@sizeOf(*T) is handle-sized for structs and arrays", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; y: i64; }
print(@sizeOf(*Point));
print(@sizeOf(?*Point));
print(@sizeOf(*[3]i64));
print(@sizeOf(*[]byte));
`),
		["8", "8", "8", "8"],
	);
});

// ---------------------------------------------------------------------------
// &struct
// ---------------------------------------------------------------------------

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

test("&struct: multiple aliases all see mutations", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$a = &p;
$b = &p;
$c = a;
a.x = 2;
print(p.x);
print(b.x);
print(c.x);
`),
		["2", "2", "2"],
	);
});

test("&struct: rebind pointer to another value", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$q = Point { x: 2 };
$r: *Point = &p;
r.x = 10;
r = &q;
r.x = 20;
print(p.x);
print(q.x);
`),
		["10", "20"],
	);
});

test("&struct: nested field write through pointer", () => {
	expectOutput(
		runSource(`
@struct Inner { v: i64; }
@struct Outer { i: Inner; }
$o = Outer { i: Inner { v: 1 } };
$p = &o;
p.i.v = 7;
print(o.i.v);
`),
		["7"],
	);
});

test("method on *T receiver mutates through pointer", () => {
	expectOutput(
		runSource(`
@struct Point {
    x: i64;
    @func bump(self: *Point) { self.x = self.x + 1; }
}
$p = Point { x: 5 };
$q = &p;
q.bump();
print(p.x);
p.bump();
print(p.x);
`),
		["6", "7"],
	);
});

// ---------------------------------------------------------------------------
// &array / &[]T / &[]byte
// ---------------------------------------------------------------------------

test("&array yields *[N]T and shares storage via index", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$p = &a;
print(@typeOf(p));
p[0] = 9;
print(a[0]);
$q = p;
q[1] = 8;
print(a[1]);
$b = a;
b[0] = 1;
print(a[0]);
`),
		["*[3]i64", "9", "8", "9"],
	);
});

test("&array with explicit *[N]T annotation", () => {
	expectOutput(
		runSource(`
$a: [3]i64 = [1, 2, 3];
$p: *[3]i64 = &a;
p[2] = 42;
print(a[2]);
print(@typeOf(p));
`),
		["42", "*[3]i64"],
	);
});

test("&array: *[]T annotation accepts *[N]T (subtype)", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$p: *[]i64 = &a;
p[0] = 5;
print(a[0]);
print(@typeOf(p));
`),
		["5", "*[]i64"],
	);
});

test("@new([]byte) is *[]byte; assign shares storage", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$arena = mem.create(0);
$buf = @new(arena, []byte, 4);
print(@typeOf(buf));
buf[0] = 1;
$p: *[]byte = buf;
p[0] = 65;
print(buf[0]);
print(p[0]);
arena.deinit();
`),
		["*[]byte", "65", "65"],
	);
});

test("@new([N]byte) pointer assign shares (no value-copy of *T)", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$arena = mem.create(0);
$buf = @new(arena, [4]byte);
print(@typeOf(buf));
buf[0] = 1;
$p = buf;
p[0] = 2;
print(buf[0]);
$c = buf;
c[0] = 3;
print(buf[0]);
print(c[0]);
arena.deinit();
`),
		["*[4]byte", "2", "3", "3"],
	);
});

test("@new([]byte): slice through *[]byte", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$arena = mem.create(0);
$buf = @new(arena, []byte, 5);
buf[0] = 65;
buf[1] = 66;
buf[2] = 67;
$s = buf[0..2];
print(len(s));
print(s[0]);
print(s[1]);
arena.deinit();
`),
		["2", "65", "66"],
	);
});

test("& value array of structs: element field via pointer index", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$a = [Point { x: 1 }, Point { x: 2 }];
$p = &a;
p[0].x = 9;
print(a[0].x);
print(a[1].x);
`),
		["9", "2"],
	);
});

test("function param *[]i64 mutates caller array", () => {
	expectOutput(
		runSource(`
@func poke(p: *[]i64) { p[0] = 99; }
$a = [1, 2, 3];
poke(&a);
print(a[0]);
`),
		["99"],
	);
});

test("function param *[N]i64 mutates caller array", () => {
	expectOutput(
		runSource(`
@func poke(p: *[3]i64) { p[1] = 7; }
$a = [1, 2, 3];
poke(&a);
print(a[1]);
`),
		["7"],
	);
});

test("function param *Point mutates caller struct", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
@func poke(p: *Point) { p.x = 42; }
$v = Point { x: 1 };
poke(&v);
print(v.x);
`),
		["42"],
	);
});

// ---------------------------------------------------------------------------
// *T assign shares; bare assign copies
// ---------------------------------------------------------------------------

test("*T assign shares; bare aggregate assign copies", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$p = &a;
$q = p;
q[0] = 9;
print(a[0]);
$b = a;
b[0] = 1;
print(a[0]);
print(b[0]);
`),
		["9", "9", "1"],
	);
});

test("*Point assign shares; Point assign copies", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$a = Point { x: 1 };
$p = &a;
$q = p;
q.x = 5;
print(a.x);
$b = a;
b.x = 2;
print(a.x);
print(b.x);
`),
		["5", "5", "2"],
	);
});

// ---------------------------------------------------------------------------
// Rejects
// ---------------------------------------------------------------------------

test("& rejects i64 scalar", () => {
	expectError(
		runSource(`
$n: i64 = 1;
$p = &n;
print(p);
`),
		"Address-of requires an aggregate value",
	);
});

test("& rejects f64 scalar", () => {
	expectError(
		runSource(`
$n: f64 = 1.5;
$p = &n;
print(p);
`),
		"Address-of requires an aggregate value",
	);
});

test("& rejects bool scalar", () => {
	expectError(
		runSource(`
$b: bool = true;
$p = &b;
print(p);
`),
		"Address-of requires an aggregate value",
	);
});

test("& rejects already-pointers (*T)", () => {
	expectError(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: i64; }
$a = mem.create(0);
$p = @new(a, Point);
$q = &p;
print(q);
`),
		"Cannot take the address of a pointer",
	);
});

test("& rejects already-pointers (*[N]T)", () => {
	expectError(
		runSource(`
$a = [1, 2, 3];
$p = &a;
$q = &p;
print(q);
`),
		"Cannot take the address of a pointer",
	);
});

test("& rejects optional aggregate", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$v = Point { x: 1 };
$o: ?Point = v;
$p = &o;
print(p);
`),
		"Cannot take the address of an optional",
	);
});

test("& rejects @const struct", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
@const $ORIGIN = Point { x: 0 };
$p = &ORIGIN;
print(p.x);
`),
		"Cannot take the address of constant",
	);
});

test("& rejects @const array", () => {
	expectError(
		runSource(`
@const $A = [1, 2, 3];
$p = &A;
p[0] = 9;
`),
		"Cannot take the address of constant",
	);
});

test("returning &frame_struct is an escape error", () => {
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

test("returning &frame_array is an escape error", () => {
	expectError(
		runSource(`
@func bad(): *[3]i64 {
    $a = [1, 2, 3];
    return &a;
}
print(bad());
`),
		"escapes its frame region",
	);
});

// ---------------------------------------------------------------------------
// Parse / sugar edge cases
// ---------------------------------------------------------------------------

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

test("parenthesized (&a)[i] mutates", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
(&a)[0] = 4;
print(a[0]);
`),
		["4"],
	);
});

test("@typeOf(&a) for struct and array", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$a = [1, 2];
print(@typeOf(&p));
print(@typeOf(&a));
`),
		["*Point", "*[2]i64"],
	);
});
