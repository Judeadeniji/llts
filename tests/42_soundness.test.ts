import { test } from "bun:test";
import { expectOutput, expectError, runSourceStrict, runSource } from "./helpers";

// =========================================================================
// Phase 1.1: Boundary Contracts on Declarations
// =========================================================================

test("strict: unannotated function parameter is rejected at compile time", () => {
	expectError(
		runSourceStrict(`
@func add(a, b: i64): i64 {
    return b;
}
pub @func main() {
    print(add(1, 2));
}
`),
		"parameter 'a' of function 'add' must have an explicit type annotation in strict mode",
	);
});

test("strict: fully annotated function parameters are accepted", () => {
	expectOutput(
		runSourceStrict(`
@func add(a: i64, b: i64): i64 {
    return a + b;
}
pub @func main() {
    print(add(10, 20));
}
`),
		["30"],
	);
});

test("strict: struct method self parameter is allowed without annotation", () => {
	expectOutput(
		runSourceStrict(`
@struct Counter {
    val: i64;
    @func get(self): i64 {
        return self.val;
    }
}
pub @func main() {
    $c = Counter{ val: 42 };
    print(c.get());
}
`),
		["42"],
	);
});

// =========================================================================
// Phase 1.2: Sound Local Synthesis
// =========================================================================

test("strict: unannotated empty array literal is rejected", () => {
	expectError(
		runSourceStrict(`
pub @func main() {
    $items = [];
}
`),
		"cannot infer type for local '$items' from empty array literal; explicit type annotation required",
	);
});

test("strict: annotated empty array literal is accepted", () => {
	expectOutput(
		runSourceStrict(`
pub @func main() {
    $items: []i64 = [];
    print(len(items));
}
`),
		["0"],
	);
});

// =========================================================================
// Phase 1.3: Contextual Literal Inference & Overflow Checking
// =========================================================================

test("strict: binary literal and numeric underscores compile and fit type", () => {
	expectOutput(
		runSourceStrict(`
pub @func main() {
    $mask: u8 = 0b0000_1111;
    $million: i64 = 1_000_000;
    print(mask);
    print(million);
}
`),
		["15", "1000000"],
	);
});

test("strict: integer literal overflow is rejected at compile time", () => {
	expectError(
		runSourceStrict(`
pub @func main() {
    $b: u8 = 300;
}
`),
		"literal 300 overflows target type 'u8'",
	);
});

// =========================================================================
// Phase 1.4: Exhaustive Return Analysis
// =========================================================================

test("strict: non-void function missing return on control path is rejected", () => {
	expectError(
		runSourceStrict(`
@func find(a: i64): i64 {
    @if (a > 0) {
        return a;
    }
}
pub @func main() {
    print(find(5));
}
`),
		"function 'find' must return a value on all control paths",
	);
});

test("strict: non-void function returning on all branches is accepted", () => {
	expectOutput(
		runSourceStrict(`
@func find(a: i64): i64 {
    @if (a > 0) {
        return a;
    } @else {
        return -a;
    }
}
pub @func main() {
    print(find(5));
    print(find(-3));
}
`),
		["5", "3"],
	);
});

test("strict: void function without return statement is accepted", () => {
	expectOutput(
		runSourceStrict(`
@func doNothing() {
}
pub @func main() {
    doNothing();
    print("ok");
}
`),
		["ok"],
	);
});

// =========================================================================
// Phase 2.1: Disallow Member Access on Optional Types
// =========================================================================

test("strict: direct member access on optional type is rejected", () => {
	expectError(
		runSourceStrict(`
@struct User {
    id: i64;
    name: string;
}
pub @func main() {
    $u: ?User = null;
    print(u.name);
}
`),
		"cannot access field 'name' on optional type '?User'; unwrap with '@if' or '.?'",
	);
});

test("strict: unwrapped optional member access is accepted", () => {
	expectOutput(
		runSourceStrict(`
@struct User {
    id: i64;
    name: string;
}
pub @func main() {
    $u: ?User = User{ id: 1, name: "Alice" };
    @if (u) |user| {
        print(user.name);
    }
}
`),
		["Alice"],
	);
});

// =========================================================================
// Phase 2.2: Mandatory Struct Completeness
// =========================================================================

test("strict: missing required non-optional struct field is rejected", () => {
	expectError(
		runSourceStrict(`
@struct User {
    id: i64;
    name: string;
}
pub @func main() {
    $u = User{ id: 1 };
}
`),
		"missing required field 'name' in initialization of 'User'",
	);
});

test("strict: optional struct field can be omitted in initialization", () => {
	expectOutput(
		runSourceStrict(`
@struct User {
    id: i64;
    name: string;
    nickname: ?string;
}
pub @func main() {
    $u = User{ id: 1, name: "Bob" };
    print(u.name);
}
`),
		["Bob"],
	);
});

// =========================================================================
// Phase 2.3: Strict @if Branching and Container Unwrapping (Option A)
// =========================================================================

test("strict: @if condition must be boolean (rejected on integer)", () => {
	expectError(
		runSourceStrict(`
pub @func main() {
    @if (42) {
        print("bad");
    }
}
`),
		"condition of @if must be boolean ('bool' or 'u1'), got 'i64'",
	);
});

test("strict: @if capture on non-container type is rejected", () => {
	expectError(
		runSourceStrict(`
pub @func main() {
    $val: int = 42;
    @if (val) |v| {
        print(v);
    }
}
`),
		"cannot capture from non-container type 'i64'; @if capture requires optional '?T' or error union",
	);
});

test("legacy: @if capture on non-container type is allowed without --strict", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $val: int = 42;
    @if (val) |v| {
        print(v);
    }
}
`),
		["42"],
	);
});

test("strict: @if capture on optional type unwraps payload", () => {
	expectOutput(
		runSourceStrict(`
pub @func main() {
    $opt: ?int = 42;
    @if (opt) |v| {
        print(v + 1);
    }
}
`),
		["43"],
	);
});
