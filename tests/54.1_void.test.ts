/**
 * Exhaustive `void` — unit / completed with no result.
 *
 * Distinct from `null` (optional absence) and `never` (noreturn / bottom).
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource, runSourceStrict } from "./helpers";

// ---------------------------------------------------------------------------
// Identity / meta
// ---------------------------------------------------------------------------

test("@typeOf / @sizeOf(void)", () => {
	expectOutput(
		runSource(`
@func f(): void { return; }
print(@typeOf(f()));
print(@sizeOf(void));
$x: void = f();
print(@sizeOf(x));
print(@typeOf(x));
`),
		["void", "0", "0", "void"],
	);
});

test("func type display includes void", () => {
	expectOutput(
		runSource(`
@func f(): void {}
print(@typeOf(f));
`),
		["@func(): void"],
	);
});

// ---------------------------------------------------------------------------
// Should work — returns
// ---------------------------------------------------------------------------

test(": void + bare return;", () => {
	expectOutput(
		runSource(`
@func f(): void { return; }
f();
print("ok");
`),
		["ok"],
	);
});

test(": void + empty body fall-through", () => {
	expectOutput(
		runSource(`
@func f(): void {}
f();
print("ok");
`),
		["ok"],
	);
});

test(": void + return other void call", () => {
	expectOutput(
		runSource(`
@func g(): void { return; }
@func f(): void { return g(); }
f();
print("ok");
`),
		["ok"],
	);
});

test("multiple early return; branches", () => {
	expectOutput(
		runSource(`
@func f(n: i64): void {
    @if (n < 0) { return; }
    @if (n > 10) { return; }
    return;
}
f(-1);
f(20);
f(3);
print("ok");
`),
		["ok"],
	);
});

test("unannotated empty fn infers void", () => {
	expectOutput(
		runSource(`
@func doNothing() {}
print(@typeOf(doNothing()));
`),
		["void"],
	);
});

test("unannotated return;-only infers void", () => {
	expectOutput(
		runSource(`
@func f() { return; }
print(@typeOf(f()));
`),
		["void"],
	);
});

test("method : void", () => {
	expectOutput(
		runSource(`
@struct Box {
    n: i64;
    @func bump(self: *Box): void { self.n = self.n + 1; }
}
$b = Box { n: 1 };
b.bump();
print(b.n);
`),
		["2"],
	);
});

// ---------------------------------------------------------------------------
// Should work — calls / binding
// ---------------------------------------------------------------------------

test("void call as expression statement", () => {
	expectOutput(
		runSource(`
@func f(): void { return; }
f();
print("next");
`),
		["next"],
	);
});

test("bind and reassign void", () => {
	expectOutput(
		runSource(`
@func f(): void {}
@func g(): void { return; }
$x: void = f();
x = g();
print(@typeOf(x));
print(x);
`),
		["void", "void"],
	);
});

test("void param and wrapper", () => {
	expectOutput(
		runSource(`
@func sink(v: void): void { return; }
@func f(): void {}
sink(f());
print("ok");
`),
		["ok"],
	);
});

test("print returns void", () => {
	expectOutput(
		runSource(`
@func say(): void { print("hi"); }
print(@typeOf(say()));
$x: void = say();
print(@typeOf(x));
`),
		["void", "hi", "void"],
	);
});

test("void equals void", () => {
	expectOutput(
		runSource(`
@func f(): void {}
@func g(): void { return; }
$a: void = f();
$b: void = g();
print(a == b);
print(a != b);
`),
		["true", "false"],
	);
});

test("void call returns to caller (contrast never)", () => {
	expectOutput(
		runSource(`
@func f(): void {}
f();
print("after");
`),
		["after"],
	);
});

// ---------------------------------------------------------------------------
// Must fail
// ---------------------------------------------------------------------------

test(": type + bare return; fails", () => {
	expectError(
		runSource(`
@func f(): i64 { return; }
print(f());
`),
		"not assignable",
	);
});

test(": type fall-through fails under strict", () => {
	expectError(
		runSourceStrict(`
@func f(): i64 {}
pub @func main() { print(f()); }
`),
		"must return a value on all control paths",
	);
});

test(": void + return 1 fails", () => {
	expectError(
		runSource(`
@func f(): void { return 1; }
f();
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

test(": void + return string fails", () => {
	expectError(
		runSource(`
@func f(): void { return "x"; }
f();
`),
		"not assignable",
	);
});

test("void in arithmetic fails", () => {
	expectError(
		runSource(`
@func f(): void {}
print(f() + 1);
`),
		"void",
	);
});

test("void field access fails", () => {
	expectError(
		runSource(`
@func f(): void {}
$x: void = f();
print(x.n);
`),
		"Undefined property",
	);
});

test("?void rejected", () => {
	expectError(
		runSource(`
$x: ?void = null;
print(x);
`),
		"cannot appear in a union",
	);
});

test("void | type rejected", () => {
	expectError(
		runSource(`
$x: void | i64 = 1;
print(x);
`),
		"cannot appear in a union",
	);
});

test("assign void to type fails", () => {
	expectError(
		runSource(`
@func f(): void {}
$n: i64 = f();
print(n);
`),
		"not assignable",
	);
});

test("assign void to null fails", () => {
	expectError(
		runSource(`
@func f(): void {}
$n: null = f();
print(n);
`),
		"not assignable",
	);
});

test("assign void to ?type fails", () => {
	expectError(
		runSource(`
@func f(): void {}
$n: ?i64 = f();
print(n);
`),
		"not assignable",
	);
});

test("assign null to void fails", () => {
	expectError(
		runSource(`
$x: void = null;
print(x);
`),
		"not assignable",
	);
});

test("assign type value to void fails", () => {
	expectError(
		runSource(`
$x: void = 1;
print(x);
`),
		"not assignable",
	);
});

test("& on void fails", () => {
	expectError(
		runSource(`
@func f(): void {}
$x: void = f();
$p = &x;
print(p);
`),
		"Address-of requires an aggregate",
	);
});

test("@addrOf(void) fails", () => {
	expectError(
		runSource(`
@func f(): void {}
$x: void = f();
print(@addrOf(x));
`),
		"@addrOf",
	);
});

// ---------------------------------------------------------------------------
// Nuances / boundaries
// ---------------------------------------------------------------------------

test("bare return; is void not null", () => {
	expectOutput(
		runSource(`
@func f() { return; }
print(@typeOf(f()));
`),
		["void"],
	);
});

test("strict: unannotated empty still accepted as void", () => {
	expectOutput(
		runSourceStrict(`
@func doNothing() {}
pub @func main() {
    doNothing();
    print(@typeOf(doNothing()));
}
`),
		["void"],
	);
});

test("mixing return; with return 1 fails once non-void expected", () => {
	expectError(
		runSource(`
@func f(n: i64): i64 {
    @if (n > 0) { return n; }
    return;
}
print(f(1));
`),
		"not assignable",
	);
});
