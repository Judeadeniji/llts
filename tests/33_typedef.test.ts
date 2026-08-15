/**
 * @type (Go-style distinct) and @alias (transparent).
 */
import { describe, expect, test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("@type UUID and ID are not interchangeable", () => {
	expectError(
		runSource(`
@type UUID = string;
@type ID = string;
$u: UUID = "abc";
$i: ID = u;
print(i);
`),
		"not assignable",
	);
});

test("@as casts between distinct types with same layout", () => {
	expectOutput(
		runSource(`
@type UUID = string;
@type ID = string;
$u: UUID = "abc";
$i: ID = @as(ID, u);
print(@typeOf(u));
print(@typeOf(i));
print(i);
`),
		["UUID", "ID", "abc"],
	);
});

test("@alias is transparent", () => {
	expectOutput(
		runSource(`
@alias Str = string;
$s: Str = "hi";
$t: string = s;
print(@typeOf(s));
print(t);
`),
		["[]byte", "hi"],
	);
});

test("@typeOf prints distinct name; @sizeOf matches underlying", () => {
	expectOutput(
		runSource(`
@type UUID = string;
$u: UUID = "xy";
print(@typeOf(u));
print(@sizeOf(UUID));
print(@sizeOf(string));
`),
		["UUID", "8", "8"],
	);
});

test("@type Expr = Literal | Add works with narrowing", () => {
	expectOutput(
		runSource(`
@enum ExprKind { Literal, Add }
@struct Literal {
    kind: ExprKind.Literal;
    value: i64;
}
@struct Add {
    kind: ExprKind.Add;
    left: i64;
    right: i64;
}
@type Expr = Literal | Add;
@func eval(e: Expr) {
    return @switch (e.kind) {
        ExprKind.Literal => { break e.value; },
        ExprKind.Add => { break e.left + e.right; },
    };
}
print(eval(Literal{ kind: ExprKind.Literal, value: 7 }));
print(eval(Add{ kind: ExprKind.Add, left: 2, right: 3 }));
`),
		["7", "5"],
	);
});

test("duplicate @type name is rejected", () => {
	expectError(
		runSource(`
@type A = i64;
@type A = string;
pub @func main() {}
`),
		"Duplicate type",
	);
});
