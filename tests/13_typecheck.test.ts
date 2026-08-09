/**
 * Gradual typechecker: annotations, sized arrays, string as []byte.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("$x: int = 1 parses and runs", () => {
	expectOutput(
		runSource(`
$x: int = 1;
print(x);
`),
		["1"],
	);
});

test("$x: i32 accepts int literal via alias normalize", () => {
	expectOutput(
		runSource(`
$x: i32 = 42;
print(x);
`),
		["42"],
	);
});

test("$x: int = string is a type error", () => {
	expectError(
		runSource(`
$x: int = "hi";
print(x);
`),
		"not assignable",
	);
});

test("annotated param mismatch is a type error", () => {
	expectError(
		runSource(`
@func add(a: int, b: int): int {
    return a + b;
}
print(add(1, "x"));
`),
		"not assignable",
	);
});

test("annotated return mismatch is a type error", () => {
	expectError(
		runSource(`
@func bad(): int {
    return "nope";
}
print(bad());
`),
		"not assignable",
	);
});

test("unannotated wrong call still compiles (gradual)", () => {
	expectOutput(
		runSource(`
@func id(a) {
    return a;
}
print(id(1));
print(id("hi"));
`),
		["1", "hi"],
	);
});

test("struct field type mismatch", () => {
	expectError(
		runSource(`
@struct Point {
    x: int;
    y: int;
}
$p = Point { x: 1, y: "bad" };
print(p.x);
`),
		"not assignable",
	);
});

test("struct usable as type annotation", () => {
	expectOutput(
		runSource(`
@struct Point {
    x: int;
    y: int;
}
$p: Point = Point { x: 1, y: 2 };
print(@typeOf(p));
print(p.x);
`),
		["Point", "1"],
	);
});

test("unknown type name is an error", () => {
	expectError(
		runSource(`
$x: NoSuchType = 1;
print(x);
`),
		"Unknown type",
	);
});

test("[]int array type annotation", () => {
	expectOutput(
		runSource(`
$a: []int = [1, 2, 3];
print(a[0]);
print(len(a));
`),
		["1", "3"],
	);
});

test("sized [N]int annotation and inference", () => {
	expectOutput(
		runSource(`
@const $a: [3]int = [1, 2, 3];
@const $b = [4, 5];
print(@typeOf(a));
print(@typeOf(b));
print(a[1]);
`),
		["[3]int", "[2]int", "2"],
	);
});

test("sized length mismatch is an error", () => {
	expectError(
		runSource(`
$a: [2]int = [1, 2, 3];
print(a[0]);
`),
		"not assignable",
	);
});

test("multidimensional [2][3]int", () => {
	expectOutput(
		runSource(`
@const $grid: [2][3]int = [[1, 2, 3], [4, 5, 6]];
print(@typeOf(grid));
print(@typeOf(grid[0]));
print(grid[1][2]);
`),
		["[2][3]int", "[3]int", "6"],
	);
});

test("nested literal length unify error", () => {
	expectError(
		runSource(`
$g = [[1, 2], [3, 4, 5]];
print(g[0][0]);
`),
		"inconsistent lengths",
	);
});

test("string is []byte; literals are [N]byte", () => {
	expectOutput(
		runSource(`
@const $msg = "hi";
$open: string = "hello";
$raw: []byte = "hello";
$exact: [5]byte = "hello";
print(@typeOf(msg));
print(@typeOf(open));
print(@typeOf(raw));
print(@typeOf(exact));
print(open);
`),
		["[2]byte", "[]byte", "[]byte", "[5]byte", "hello"],
	);
});

test("string length mismatch [3]byte = hi", () => {
	expectError(
		runSource(`
$s: [3]byte = "hi";
print(s);
`),
		"not assignable",
	);
});

test("T | error and ? unwrap", () => {
	expectOutput(
		runSource(`
@func ok(): string | error {
    return "yes";
}
@func main(): string | error {
    $s = ok()?;
    print(s);
    return s;
}
`),
		["yes"],
	);
});

test("boolean alias normalizes to bool", () => {
	expectOutput(
		runSource(`
$b: boolean = true;
print(b);
`),
		["true"],
	);
});

test("@typeOf prints annotated and inferred types", () => {
	expectOutput(
		runSource(`
$x: int = 1;
$y = "hi";
$z: []int = [1, 2];
print(@typeOf(x));
print(@typeOf(y));
print(@typeOf(z));
print(@typeOf(true));
`),
		["int", "[2]byte", "[]int", "bool"],
	);
});

test("@typeOf on T | error and after ?", () => {
	expectOutput(
		runSource(`
@func f(): string | error {
    return "ok";
}
print(@typeOf(f()));
$s = f()?;
print(@typeOf(s));
`),
		["[]byte | error", "[]byte"],
	);
});

test("@typeOf arity must be 1", () => {
	expectError(
		runSource(`
print(@typeOf(1, 2));
`),
		"@typeOf expects exactly 1 argument",
	);
});
