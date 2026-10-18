/**
 * Exhaustive `never` — noreturn / bottom.
 *
 * Distinct from `void` (completes with unit) and `null` (optional absence).
 * Never has no runtime value; calls do not return to the caller.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// ---------------------------------------------------------------------------
// Identity / meta
// ---------------------------------------------------------------------------

test("@typeOf(never call) is never; @sizeOf(never) rejected", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
print(@typeOf(die()));
`),
		["never"],
	);
	expectError(
		runSource(`
print(@sizeOf(never));
`),
		"has no static size",
	);
});

test("never is a builtin type name", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
print(@typeOf(die));
`),
		["@func(): never"],
	);
});

// ---------------------------------------------------------------------------
// Should work — noreturn functions
// ---------------------------------------------------------------------------

test(": never body ending in __exit call", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
print(@typeOf(die()));
`),
		["never"],
	);
});

test(": never body ending in another never call", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func boom(): never { die(); }
print(@typeOf(boom()));
`),
		["never"],
	);
});

test("std/os.exit is never", () => {
	expectOutput(
		runSource(`
@const $os = @import("std/os");
print(@typeOf(os.exit(1)));
`),
		["never"],
	);
});

// ---------------------------------------------------------------------------
// Should work — bottom at call sites (compile only; do not invoke)
// ---------------------------------------------------------------------------

test("return neverCall() legal in : type", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func f(): i64 { return die(); }
print(@typeOf(f));
`),
		["@func(): i64"],
	);
});

test("return neverCall() legal in : void", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func f(): void { return die(); }
print(@typeOf(f));
`),
		["@func(): void"],
	);
});

test("return neverCall() legal in : never", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func boom(): never { return die(); }
print(@typeOf(boom()));
`),
		["never"],
	);
});

test("$x: type = neverCall() typechecks when not executed", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func f(): i64 {
    $x: i64 = die();
    return x;
}
print(@typeOf(f));
`),
		["@func(): i64"],
	);
});

test("never call as any-typed argument (unchecked at runtime)", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func take(n: i64): i64 { return n; }
@func f(): i64 { return take(die()); }
print(@typeOf(f));
`),
		["@func(): i64"],
	);
});

test("code after never-call path not required to return", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func f(n: i64): i64 {
    @if (n < 0) {
        return die();
    }
    return n;
}
print(f(3));
`),
		["3"],
	);
});

// ---------------------------------------------------------------------------
// Must fail
// ---------------------------------------------------------------------------

test(": never + bare return; fails", () => {
	expectError(
		runSource(`
@func die(): never { return; }
die();
`),
		"Cannot 'return;'",
	);
});

test(": never + return 1 fails", () => {
	expectError(
		runSource(`
@func die(): never { return 1; }
die();
`),
		"Cannot return a value",
	);
});

test(": never + return null fails", () => {
	expectError(
		runSource(`
@func die(): never { return null; }
die();
`),
		"Cannot return a value",
	);
});

test(": never + return void call fails", () => {
	expectError(
		runSource(`
@func g(): void {}
@func die(): never { return g(); }
die();
`),
		"Cannot return a value",
	);
});

test(": never + empty body / fall-through fails", () => {
	expectError(
		runSource(`
@func die(): never {}
die();
`),
		"can complete normally",
	);
});

test(": never with incomplete if path fails", () => {
	expectError(
		runSource(`
@func die(): never {
    @if (true) {
        __exit(1);
    }
}
die();
`),
		"can complete normally",
	);
});

test("?never rejected", () => {
	expectError(
		runSource(`
$x: ?never = null;
print(x);
`),
		"cannot appear in a union",
	);
});

test("never | type rejected", () => {
	expectError(
		runSource(`
$x: never | i64 = 1;
print(x);
`),
		"cannot appear in a union",
	);
});

test("void | never rejected", () => {
	expectError(
		runSource(`
$x: void | never = 1;
print(x);
`),
		"cannot appear in a union",
	);
});

// ---------------------------------------------------------------------------
// Behavior / runtime
// ---------------------------------------------------------------------------

test("never call exits the process", () => {
	const r = runSource(`
@func die(): never { __exit(7); }
die();
print("unreachable");
`);
	if (r.exitCode !== 7) {
		throw new Error(`Expected exit 7, got ${r.exitCode}.\nstderr: ${r.stderr}\nstdout: ${r.stdout}`);
	}
	if (r.stdout.includes("unreachable")) {
		throw new Error(`never call returned to caller:\n${r.stdout}`);
	}
});

test("void call continues; never would not", () => {
	expectOutput(
		runSource(`
@func f(): void {}
f();
print("after-void");
`),
		["after-void"],
	);
});

// ---------------------------------------------------------------------------
// Nuances / boundaries
// ---------------------------------------------------------------------------

test("never ≠ void", () => {
	expectOutput(
		runSource(`
@func v(): void {}
@func n(): never { __exit(1); }
print(@typeOf(v()));
print(@typeOf(n()));
`),
		["void", "never"],
	);
});

test("never ≠ null", () => {
	expectOutput(
		runSource(`
@func n(): never { __exit(1); }
print(@typeOf(null));
print(@typeOf(n()));
`),
		["null", "never"],
	);
});

test("never ⊑ void at return (bottom)", () => {
	expectOutput(
		runSource(`
@func die(): never { __exit(1); }
@func f(): void { return die(); }
print(@typeOf(f));
`),
		["@func(): void"],
	);
});
