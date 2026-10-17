/**
 * Exhaustive `@addrOf(x)` coverage.
 *
 * Model: packed-heap identity as `i64` (offset). Equal for aliases (`&x` /
 * `*T` assign / `@new`); diverges after value copy. Accepts addressable
 * aggregates and `*T`; rejects scalars and optionals.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// ---------------------------------------------------------------------------
// Result type
// ---------------------------------------------------------------------------

test("@typeOf(@addrOf(x)) is i64 for struct and *T", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$q = &p;
print(@typeOf(@addrOf(p)));
print(@typeOf(@addrOf(q)));
`),
		["i64", "i64"],
	);
});

test("@addrOf result can be stored and compared", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$a: i64 = @addrOf(p);
$q = &p;
$b: i64 = @addrOf(q);
$c = p;
$d: i64 = @addrOf(c);
print(a == b);
print(a == d);
`),
		["true", "false"],
	);
});

// ---------------------------------------------------------------------------
// Struct / *Struct
// ---------------------------------------------------------------------------

test("@addrOf struct equals @addrOf(&struct)", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$q = &p;
print(@addrOf(p) == @addrOf(q));
print(@addrOf(p) == @addrOf(&p));
`),
		["true", "true"],
	);
});

test("@addrOf struct: *T assign shares; value assign diverges", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$a = Point { x: 1 };
$p = &a;
$q = p;
$b = a;
print(@addrOf(a) == @addrOf(p));
print(@addrOf(p) == @addrOf(q));
print(@addrOf(a) == @addrOf(b));
`),
		["true", "true", "false"],
	);
});

test("@addrOf struct: multiple & aliases agree", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$a = &p;
$b = &p;
print(@addrOf(p) == @addrOf(a));
print(@addrOf(a) == @addrOf(b));
`),
		["true", "true"],
	);
});

test("@addrOf struct: rebind pointer changes identity", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$q = Point { x: 2 };
$r: *Point = &p;
print(@addrOf(r) == @addrOf(p));
r = &q;
print(@addrOf(r) == @addrOf(q));
print(@addrOf(r) == @addrOf(p));
`),
		["true", "true", "false"],
	);
});

test("@addrOf struct stable across field mutation", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
$a = @addrOf(p);
p.x = 99;
$q = &p;
q.x = 7;
print(@addrOf(p) == a);
print(@addrOf(q) == a);
`),
		["true", "true"],
	);
});

test("@addrOf @new(Point) equals pointer aliases", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point { x: i64; }
$arena = mem.create(0);
$p = @new(arena, Point);
$q = p;
print(@addrOf(p) == @addrOf(q));
print(@typeOf(@addrOf(p)));
arena.deinit();
`),
		["true", "i64"],
	);
});

test("@addrOf nested struct field is distinct from outer", () => {
	expectOutput(
		runSource(`
@struct Inner { v: i64; }
@struct Outer { i: Inner; }
$o = Outer { i: Inner { v: 1 } };
print(@addrOf(o) == @addrOf(o.i));
$p = &o;
print(@addrOf(o) == @addrOf(p));
`),
		["false", "true"],
	);
});

// ---------------------------------------------------------------------------
// Array / *[N]T / *[]T
// ---------------------------------------------------------------------------

test("@addrOf [N]T equals @addrOf(&array)", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$p = &a;
print(@typeOf(p));
print(@addrOf(a) == @addrOf(p));
print(@addrOf(a) == @addrOf(&a));
`),
		["*[3]i64", "true", "true"],
	);
});

test("@addrOf [N]T: *T assign shares; value assign diverges", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$p = &a;
$q = p;
$b = a;
print(@addrOf(a) == @addrOf(p));
print(@addrOf(p) == @addrOf(q));
print(@addrOf(a) == @addrOf(b));
`),
		["true", "true", "false"],
	);
});

test("@addrOf array stable across index mutation", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$before = @addrOf(a);
$p = &a;
p[0] = 9;
a[1] = 8;
print(@addrOf(a) == before);
print(@addrOf(p) == before);
`),
		["true", "true"],
	);
});

test("@addrOf *[N]T via *[]T annotation still shares", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
$p: *[]i64 = &a;
print(@addrOf(a) == @addrOf(p));
`),
		["true"],
	);
});

test("@addrOf array of structs shares with &", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$a = [Point { x: 1 }, Point { x: 2 }];
$p = &a;
print(@addrOf(a) == @addrOf(p));
$b = a;
print(@addrOf(a) == @addrOf(b));
`),
		["true", "false"],
	);
});

// ---------------------------------------------------------------------------
// []byte / *[]byte / @new
// ---------------------------------------------------------------------------

test("@addrOf string ([]byte) equals @addrOf(&s)", () => {
	expectOutput(
		runSource(`
$s = "hello";
$p = &s;
print(@addrOf(s) == @addrOf(p));
$t = s;
print(@addrOf(s) == @addrOf(t));
`),
		["true", "false"],
	);
});

test("@addrOf @new([]byte) stable across *T aliases", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$arena = mem.create(0);
$buf = @new(arena, []byte, 4);
$p = buf;
$q = p;
print(@typeOf(buf));
print(@addrOf(buf) == @addrOf(p));
print(@addrOf(p) == @addrOf(q));
arena.deinit();
`),
		["*[]byte", "true", "true"],
	);
});

test("@addrOf @new([N]byte) shares across pointer assign", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$arena = mem.create(0);
$buf = @new(arena, [4]byte);
$p = buf;
print(@typeOf(buf));
print(@addrOf(buf) == @addrOf(p));
arena.deinit();
`),
		["*[4]byte", "true"],
	);
});

test("@addrOf []byte stable across element writes", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
$arena = mem.create(0);
$buf = @new(arena, []byte, 4);
$a = @addrOf(buf);
buf[0] = 65;
$p = buf;
p[1] = 66;
print(@addrOf(buf) == a);
print(@addrOf(p) == a);
arena.deinit();
`),
		["true", "true"],
	);
});

// ---------------------------------------------------------------------------
// Tuple / *tuple
// ---------------------------------------------------------------------------

test("@addrOf tuple equals @addrOf(&tuple)", () => {
	expectOutput(
		runSource(`
$t: [i64, []byte] = [1, "a"];
$p = &t;
print(@typeOf(p));
print(@addrOf(t) == @addrOf(p));
$u = t;
print(@addrOf(t) == @addrOf(u));
`),
		["*[i64, []byte]", "true", "false"],
	);
});

test("@addrOf tuple stable across element mutation", () => {
	expectOutput(
		runSource(`
$t: [i64, []byte] = [1, "a"];
$a = @addrOf(t);
$p = &t;
t.0 = 9;
t[1] = "b";
print(@addrOf(t) == a);
print(@addrOf(p) == a);
`),
		["true", "true"],
	);
});

// ---------------------------------------------------------------------------
// Shape / *shape
// ---------------------------------------------------------------------------

test("@addrOf shape equals @addrOf(&shape)", () => {
	expectOutput(
		runSource(`
@type Point = { x: i64; y: i64; };
$p = Point { x: 1, y: 2 };
$q = &p;
print(@typeOf(q));
print(@addrOf(p) == @addrOf(q));
$r = p;
print(@addrOf(p) == @addrOf(r));
`),
		["*Point", "true", "false"],
	);
});

test("@addrOf structural shape via @type coerce", () => {
	expectOutput(
		runSource(`
@type Box = { n: i64; };
$s: { n: i64; } = Box { n: 3 };
$p = &s;
print(@addrOf(s) == @addrOf(p));
$t = s;
print(@addrOf(s) == @addrOf(t));
`),
		["true", "false"],
	);
});

// ---------------------------------------------------------------------------
// Function params / returns
// ---------------------------------------------------------------------------

test("@addrOf of *T param matches caller aggregate", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
@func addr(p: *Point) {
    return @addrOf(p);
}
$v = Point { x: 1 };
print(addr(&v) == @addrOf(v));
`),
		["true"],
	);
});

test("@addrOf of array *T param matches caller", () => {
	expectOutput(
		runSource(`
@func addr(p: *[3]i64) {
    return @addrOf(p);
}
$a = [1, 2, 3];
print(addr(&a) == @addrOf(a));
`),
		["true"],
	);
});

// ---------------------------------------------------------------------------
// @const / @type alias
// ---------------------------------------------------------------------------

test("@addrOf accepts @const struct (read-only identity)", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
@const $p = Point { x: 1 };
print(@typeOf(@addrOf(p)));
print(@addrOf(p) == @addrOf(p));
`),
		["i64", "true"],
	);
});

test("@addrOf accepts @const array", () => {
	expectOutput(
		runSource(`
@const $a = [1, 2, 3];
print(@addrOf(a) == @addrOf(a));
`),
		["true"],
	);
});

test("@addrOf on @type alias of struct", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
@type P = Point;
$v: P = Point { x: 1 };
$q = &v;
print(@addrOf(v) == @addrOf(q));
`),
		["true"],
	);
});

// ---------------------------------------------------------------------------
// Rejects — scalars
// ---------------------------------------------------------------------------

test("@addrOf rejects i64", () => {
	expectError(
		runSource(`
$n: i64 = 1;
print(@addrOf(n));
`),
		"@addrOf requires an aggregate or *T",
	);
});

test("@addrOf rejects f64", () => {
	expectError(
		runSource(`
$n: f64 = 1.5;
print(@addrOf(n));
`),
		"@addrOf requires an aggregate or *T",
	);
});

test("@addrOf rejects bool", () => {
	expectError(
		runSource(`
$b: bool = true;
print(@addrOf(b));
`),
		"@addrOf requires an aggregate or *T",
	);
});

test("@addrOf rejects enum", () => {
	expectError(
		runSource(`
@enum Color { Red, Green }
$c = Color.Red;
print(@addrOf(c));
`),
		"@addrOf requires an aggregate or *T",
	);
});

// ---------------------------------------------------------------------------
// Rejects — optionals
// ---------------------------------------------------------------------------

test("@addrOf rejects optional struct", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$v = Point { x: 1 };
$o: ?Point = v;
print(@addrOf(o));
`),
		"@addrOf does not accept optionals",
	);
});

test("@addrOf rejects optional array", () => {
	expectError(
		runSource(`
$a = [1, 2, 3];
$o: ?[3]i64 = a;
print(@addrOf(o));
`),
		"@addrOf does not accept optionals",
	);
});

test("@addrOf rejects ?*T", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$v = Point { x: 1 };
$o: ?*Point = &v;
print(@addrOf(o));
`),
		"@addrOf does not accept optionals",
	);
});

test("@addrOf rejects null", () => {
	expectError(
		runSource(`
print(@addrOf(null));
`),
		"@addrOf",
	);
});

// ---------------------------------------------------------------------------
// Arity
// ---------------------------------------------------------------------------

test("@addrOf arity must be 1", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
print(@addrOf());
`),
		"@addrOf expects exactly 1 argument",
	);
});

test("@addrOf rejects extra arguments", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$p = Point { x: 1 };
print(@addrOf(p, p));
`),
		"@addrOf expects exactly 1 argument",
	);
});
