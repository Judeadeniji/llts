/**
 * Object / shape types `{ field: T; … }` — structural; `@type` names stay nominal.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("@type shape init, fields, typeOf, sizeOf", () => {
	expectOutput(
		runSource(`
@type Counter = { value: i64; };
$c = Counter { value: 7 };
print(@typeOf(c));
print(c.value);
c.value = 9;
print(c.value);
print(@sizeOf(Counter));
`),
		["Counter", "7", "9", "8"],
	);
});

test("identical @type shapes are not interchangeable", () => {
	expectError(
		runSource(`
@type A = { x: i64; };
@type B = { x: i64; };
$a = A { x: 1 };
$b: B = a;
print(b.x);
`),
		"not assignable",
	);
});

test("coerce shape into @type and @type into structural param", () => {
	expectOutput(
		runSource(`
@type Point = { x: i64; y: i64; };
$raw: { x: i64; y: i64; } = Point { x: 1, y: 2 };
$p: Point = raw;
print(@typeOf(p));
print(p.x);
print(p.y);

@func take(q: { x: i64; }) {
  print(q.x);
}
take(p);
`),
		["Point", "1", "2", "1"],
	);
});

test("shape may declare @func fields (type-level)", () => {
	expectOutput(
		runSource(`
@type Readable = { read: @func([]byte): i64; };
print(@sizeOf(Readable));
`),
		["8"],
	);
});

test("unknown field on shape is an error", () => {
	expectError(
		runSource(`
@type S = { a: i64; };
$s = S { a: 1 };
print(s.missing);
`),
		"does not exist",
	);
});

test("multi-field shape layout", () => {
	expectOutput(
		runSource(`
@type Pair = { a: i64; b: i64; };
$p = Pair { a: 3, b: 4 };
print(p.a);
print(p.b);
print(@sizeOf(Pair));
`),
		["3", "4", "16"],
	);
});

test("Readable & Writable merges into @type Rw", () => {
	expectOutput(
		runSource(`
@type Readable = { read: i64; };
@type Writable = { write: i64; };
@type Rw = Readable & Writable;
$r = Rw { read: 1, write: 2 };
print(@typeOf(r));
print(r.read);
print(r.write);
print(@sizeOf(Rw));
`),
		["Rw", "1", "2", "16"],
	);
});

test("intersection value satisfies narrower structural param", () => {
	expectOutput(
		runSource(`
@type Readable = { read: i64; };
@type Writable = { write: i64; };
@type Rw = Readable & Writable;
@func needsRead(p: { read: i64; }) {
  print(p.read);
}
needsRead(Rw { read: 9, write: 0 });
`),
		["9"],
	);
});

test("& rejects non-shape arms", () => {
	expectError(
		runSource(`
@type Bad = i64 & { x: i64; };
`),
		"only on shape types",
	);
});

test("conflicting field types in intersection is an error", () => {
	expectError(
		runSource(`
@type A = { x: i64; };
@type B = { x: string; };
@type C = A & B;
`),
		"conflicting types",
	);
});

test("& binds tighter than |", () => {
	// If & were looser, ({a}|{b}) & {c} would reject non-shape union.
	expectOutput(
		runSource(`
@type U = { a: i64; } | { b: i64; } & { c: i64; };
print(@sizeOf(U));
`),
		["8"],
	);
});

test("annotated bare init $p: Point = { … }", () => {
	expectOutput(
		runSource(`
@type Point = { x: i64; y: i64; };
$p: Point = { x: 1, y: 2 };
print(@typeOf(p));
print(p.x);
print(p.y);
`),
		["Point", "1", "2"],
	);
});

test("annotated bare init works for @struct too", () => {
	expectOutput(
		runSource(`
@struct Point {
  x: i64;
  y: i64;
}
$p: Point = { x: 3, y: 4 };
print(p.x);
print(p.y);
`),
		["3", "4"],
	);
});

test("callable value in shape field", () => {
	expectOutput(
		runSource(`
@type Box = { get: @func(): i64; };
@func forty(): i64 { return 40; }
$b = Box { get: forty };
print(b.get());
`),
		["40"],
	);
});
