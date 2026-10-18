/**
 * Exhaustive `null` — optional absence only.
 *
 * Distinct from `void` (unit / no result) and `never` (noreturn / bottom).
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource, runSourceStrict } from "./helpers";

// ---------------------------------------------------------------------------
// Identity / meta
// ---------------------------------------------------------------------------

test("@typeOf(null) / @sizeOf(null)", () => {
	expectOutput(
		runSource(`
print(@typeOf(null));
print(@sizeOf(null));
`),
		["null", "0"],
	);
});

test("?T sugar equals T | null", () => {
	expectOutput(
		runSource(`
$x: ?i64 = null;
$y: i64 | null = null;
print(@typeOf(x));
print(@typeOf(y));
print(x);
print(y);
`),
		["?i64", "?i64", "null", "null"],
	);
});

// ---------------------------------------------------------------------------
// Should work — optional absence
// ---------------------------------------------------------------------------

test("optional scalar bind / rebind null", () => {
	expectOutput(
		runSource(`
$x: ?i64 = null;
print(x);
x = 7;
print(x);
x = null;
print(x);
`),
		["null", "7", "null"],
	);
});

test("?*T null then bind pointer", () => {
	expectOutput(
		runSource(`
@struct Point { x: i64; }
$v = Point { x: 1 };
$p: ?*Point = null;
print(p == null);
p = &v;
print(p.x);
p = null;
print(p == null);
`),
		["true", "1", "true"],
	);
});

test("optional struct field with null", () => {
	expectOutput(
		runSource(`
@struct Node {
    value: i64;
    next: ?Node;
}
$n = Node { value: 1, next: null };
print(n.next);
`),
		["null"],
	);
});

test("return null from ?T", () => {
	expectOutput(
		runSource(`
@func miss(): ?i64 { return null; }
@func hit(): ?i64 { return 3; }
print(miss());
print(hit());
`),
		["null", "3"],
	);
});

test("return null from T | null", () => {
	expectOutput(
		runSource(`
@func miss(): i64 | null { return null; }
print(miss());
`),
		["null"],
	);
});

test("null check narrowing", () => {
	expectOutput(
		runSource(`
$x: ?i64 = 9;
@if (x != null) {
    print(x);
} @else {
    print("no");
}
x = null;
@if (x == null) {
    print("yes");
}
`),
		["9", "yes"],
	);
});

test("pass null to ?T param", () => {
	expectOutput(
		runSource(`
@func take(x: ?i64): ?i64 { return x; }
print(take(null));
print(take(2));
`),
		["null", "2"],
	);
});

test("@const null", () => {
	expectOutput(
		runSource(`
@const $z = null;
print(z);
print(@typeOf(z));
`),
		["null", "null"],
	);
});

test("print shows null not void", () => {
	expectOutput(
		runSource(`
$x: ?i64 = null;
print(x);
`),
		["null"],
	);
});

test("null is falsy", () => {
	expectOutput(
		runSource(`
$x: ?i64 = null;
@if (x) { print("t"); } @else { print("f"); }
`),
		["f"],
	);
});

// ---------------------------------------------------------------------------
// Must fail
// ---------------------------------------------------------------------------

test(": null as function return type rejected", () => {
	expectError(
		runSource(`
@func f(): null { return null; }
print(f());
`),
		"Function return type cannot be 'null'",
	);
});

test(": type + return null fails", () => {
	expectError(
		runSource(`
@func f(): i64 { return null; }
print(f());
`),
		"not assignable",
	);
});

test(": void + return null fails", () => {
	expectError(
		runSource(`
@func f(): void { return null; }
f();
`),
		"not assignable",
	);
});

test("null not assignable to type", () => {
	expectError(
		runSource(`
$n: i64 = null;
print(n);
`),
		"not assignable",
	);
});

test("null not assignable to struct", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$p: Point = null;
print(p.x);
`),
		"not assignable",
	);
});

test("null not assignable to *T", () => {
	expectError(
		runSource(`
@struct Point { x: i64; }
$v = Point { x: 1 };
$p: *Point = null;
print(p.x);
`),
		"not assignable",
	);
});

test("null not assignable to void", () => {
	expectError(
		runSource(`
$x: void = null;
print(x);
`),
		"not assignable",
	);
});

test("strict: member access on optional rejected", () => {
	expectError(
		runSourceStrict(`
@struct User { name: []byte; }
$u: ?User = null;
print(u.name);
pub @func main() {}
`),
		"optional",
	);
});

// ---------------------------------------------------------------------------
// Nuances / boundaries
// ---------------------------------------------------------------------------

test("return null is not bare return;", () => {
	expectOutput(
		runSource(`
@func a(): ?i64 { return null; }
@func b(): void { return; }
print(@typeOf(a()));
print(@typeOf(b()));
`),
		["?i64", "void"],
	);
});

test("null ⊑ ?T; void ⊄ ?T", () => {
	expectOutput(
		runSource(`
$x: ?i64 = null;
print(x);
`),
		["null"],
	);
	expectError(
		runSource(`
@func f(): void {}
$x: ?i64 = f();
print(x);
`),
		"not assignable",
	);
});

test("narrowing yields payload or null, not void", () => {
	expectOutput(
		runSource(`
$x: ?i64 = 4;
@if (x != null) {
    print(x);
    print(@typeOf(null));
}
`),
		["4", "null"],
	);
});
