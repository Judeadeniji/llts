/**
 * @type (Go-style distinct) and @alias (transparent).
 */
import { test } from "bun:test";
import { expectError, expectOutput, runFile, runSource } from "./helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

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

test("T(x) cast sugar for distinct @type names", () => {
	expectOutput(
		runSource(`
@type UUID = string;
@type ID = string;
$u: UUID = "abc";
$i: ID = ID(u);
print(@typeOf(i));
print(i);
`),
		["ID", "abc"],
	);
});

test("T(x) still calls functions when Name is a function", () => {
	expectOutput(
		runSource(`
@func add(a: i64): i64 { return a + 1; }
print(add(41));
`),
		["42"],
	);
});

test("T(x) rejects impossible cast", () => {
	expectError(
		runSource(`
@type UUID = string;
$n: i64 = 1;
$u = UUID(n);
`),
		"cannot cast",
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

test("string literal types", () => {
	expectOutput(
		runSource(`
@type KindA = "a";
@type KindB = "b";
@type Kind = KindA | KindB;
$k: KindA = "a";
print(@typeOf(k));
print(k);
$m: Kind = "b";
print(@typeOf(m));
`),
		["KindA", "a", "Kind"],
	);
});

test("wrong string literal is rejected", () => {
	expectError(
		runSource(`
@type KindA = "a";
$k: KindA = "b";
print(k);
`),
		"not assignable",
	);
});

test("int and bool literal types", () => {
	expectOutput(
		runSource(`
@type Zero = 0;
@type Yes = true;
$z: Zero = 0;
$y: Yes = true;
print(@typeOf(z));
print(@typeOf(y));
print(z);
print(y);
`),
		["Zero", "Yes", "0", "true"],
	);
});

test("bare literal type annotation", () => {
	expectOutput(
		runSource(`
$k: "a" = "a";
print(@typeOf(k));
print(k);
`),
		['"a"', "a"],
	);
});

test("literal union KindA | KindB", () => {
	expectOutput(
		runSource(`
@type Kind = "a" | "b";
$k: Kind = "a";
print(k);
$k2: Kind = "b";
print(k2);
`),
		["a", "b"],
	);
});

test("function type: annotate, assign, call, @typeOf", () => {
	expectOutput(
		runSource(`
@func add(a: i64, b: i64): i64 { return a + b; }
@type Handler = @func(i64, i64): i64;
$f: Handler = add;
print(@typeOf(f));
print(@typeOf(add));
print(f(2, 3));
print(@sizeOf(Handler));
`),
		["Handler", "@func(i64, i64): i64", "5", "8"],
	);
});

test("function type arity mismatch is an error", () => {
	expectError(
		runSource(`
@func add(a: i64, b: i64): i64 { return a + b; }
$f: @func(i64, i64): i64 = add;
print(f(1));
`),
		"expected 2 arguments",
	);
});

test("function type assignability rejects wrong signature", () => {
	expectError(
		runSource(`
@func add(a: i64, b: i64): i64 { return a + b; }
$f: @func(i64): i64 = add;
print(f(1));
`),
		"not assignable",
	);
});

test("*Arm assigns to *Union field (covariant pointers)", () => {
	expectOutput(
		runSource(`
@enum Kind { Lit, Bin }
@struct Lit { kind: Kind.Lit; value: i64; }
@struct Bin { kind: Kind.Bin; left: *Expr; right: *Expr; }
@type Expr = Lit | Bin;
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = @new(a, Lit { kind: Kind.Lit, value: 9 });
$b = @new(a, Bin { kind: Kind.Bin, left: l, right: l });
print(b.kind);
print(l.value);
a.deinit();
`),
		["1", "9"],
	);
});

test("forward-ref: struct fields may name @type declared later", () => {
	expectOutput(
		runSource(`
@enum Kind { Lit, Bin }
@struct Lit { kind: Kind.Lit; value: i64; }
@struct Bin { kind: Kind.Bin; left: *Expr; right: *Expr; }
@type Expr = Lit | Bin;
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = @new(a, Lit { kind: Kind.Lit, value: 3 });
$b = @new(a, Bin { kind: Kind.Bin, left: l, right: l });
print(l.value);
print(@typeOf(b));
a.deinit();
`),
		["3", "*Bin"],
	);
});

test("@as(*Union, *Arm) is allowed", () => {
	expectOutput(
		runSource(`
@enum Kind { Lit, Bin }
@struct Lit { kind: Kind.Lit; value: i64; }
@struct Bin { kind: Kind.Bin; left: i64; right: i64; }
@type Expr = Lit | Bin;
@const $mem = @import("std/mem");
$a = mem.create(0);
$l: *Expr = @as(*Expr, @new(a, Lit { kind: Kind.Lit, value: 4 }));
print(@typeOf(l));
print(l.kind);
a.deinit();
`),
		["*Expr", "0"],
	);
});

test("imported @type Lit | Bin rewrites arm names", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_typedef_"));
	try {
		fs.writeFileSync(
			path.join(dir, "node.lls"),
			`
pub @enum Kind { Lit, Bin }
pub @struct Lit { kind: Kind.Lit; value: i64; }
pub @struct Bin { kind: Kind.Bin; left: *Node; right: *Node; }
pub @type Node = Lit | Bin;
`,
		);
		fs.writeFileSync(
			path.join(dir, "use.lls"),
			`
@const $n = @import("./node.lls");
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = @new(a, n.Lit { kind: n.Kind.Lit, value: 7 });
$b = @new(a, n.Bin { kind: n.Kind.Bin, left: l, right: l });
print(b.kind);
print(l.value);
pub @func main() {}
`,
		);
		expectOutput(runFile(path.join(dir, "use.lls")), ["1", "7"]);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});
