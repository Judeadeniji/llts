/**
 * @enum declarations: auto-int variants, type annotations, modules.
 */
import { test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { expectError, expectOutput, runFile, runSource } from "./helpers";

function withTempModules(
	files: Record<string, string>,
	entryRel: string,
): { dir: string; entry: string } {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_enum_"));
	for (const [rel, src] of Object.entries(files)) {
		const full = path.join(dir, rel);
		fs.mkdirSync(path.dirname(full), { recursive: true });
		fs.writeFileSync(full, src, "utf-8");
	}
	return { dir, entry: path.join(dir, entryRel) };
}

test("@enum variants are auto-incrementing ints", () => {
	expectOutput(
		runSource(`
@enum Color { Red, Green, Blue }
print(Color.Red);
print(Color.Green);
print(Color.Blue);
`),
		["0", "1", "2"],
	);
});

test("$x: Enum = Enum.Variant typechecks and runs", () => {
	expectOutput(
		runSource(`
@enum Tok { EOF, ID }
$x: Tok = Tok.ID;
print(x);
print(@typeOf(x));
`),
		["1", "Tok"],
	);
});

test("enum variants compare equal to their int values", () => {
	expectOutput(
		runSource(`
@enum Color { Red, Green }
print(Color.Red == 0);
print(Color.Green == 1);
print(Color.Red == Color.Green);
`),
		["true", "true", "false"],
	);
});

test("@const accepts enum variant initializers", () => {
	expectOutput(
		runSource(`
@enum Color { Red, Green }
@const $c = Color.Green;
print(c);
`),
		["1"],
	);
});

test("@const enum variant cannot be reassigned", () => {
	expectError(
		runSource(`
@enum Color { Red, Green }
@const $c = Color.Green;
c = 0;
`),
		"constant",
	);
});

test("unknown enum variant is a compile error", () => {
	expectError(
		runSource(`
@enum Color { Red }
print(Color.Nope);
`),
		"Unknown enum variant",
	);
});

test("duplicate enum variant is a compile error", () => {
	expectError(
		runSource(`
@enum Color { Red, Red }
`),
		"Duplicate enum variant",
	);
});

test("pub @enum is visible across modules", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
pub @enum Tok { EOF, ID, NUM }
`,
			"main.lls": `
$lib = @import("./lib.lls");
print(lib.Tok.EOF);
print(lib.Tok.NUM);
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectOutput(runFile(entry), ["0", "2"]);
});

test("private @enum is not exported", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
@enum Hidden { A, B }
`,
			"main.lls": `
$lib = @import("./lib.lls");
print(lib.Hidden.A);
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectError(runFile(entry), "has no export");
});

test("@switch on enum requires exhaustiveness or @else", () => {
	expectError(
		runSource(`
@enum Color { Red, Green, Blue }
@switch (Color.Red) {
    Color.Red => { print("r"); },
}
`),
		"missing enum variant",
	);
});

test("exhaustive value @switch needs no @else", () => {
	expectOutput(
		runSource(`
@enum Color { Red, Green }
$x = @switch (Color.Green) {
    Color.Red => { break 1; },
    Color.Green => { break 2; },
};
print(x);
`),
		["2"],
	);
});

test("discriminated struct + kind enum (preferred tagged data)", () => {
	expectOutput(
		runSource(`
@enum ExprKind { Literal, Add }
@struct Expr {
    kind: ExprKind;
    value: i64;
    left: i64;
    right: i64;
}
$a = Expr{ kind: ExprKind.Literal, value: 42, left: 0, right: 0 };
$b = Expr{ kind: ExprKind.Add, value: 0, left: 3, right: 4 };
$n = @switch (a.kind) {
    ExprKind.Literal => { break a.value; },
    ExprKind.Add => { break a.left + a.right; },
};
$m = @switch (b.kind) {
    ExprKind.Literal => { break b.value; },
    ExprKind.Add => { break b.left + b.right; },
};
print(n);
print(m);
`),
		["42", "7"],
	);
});

test("kind: Enum.Variant singleton field types", () => {
	expectOutput(
		runSource(`
@enum ExprKind { Literal, Add }
@struct Literal {
    kind: ExprKind.Literal;
    value: i64;
}
$a = Literal{ kind: ExprKind.Literal, value: 42 };
print(a.value);
print(@typeOf(a.kind));
`),
		["42", "ExprKind.Literal"],
	);
});

test("wrong Enum.Variant rejected for singleton kind field", () => {
	expectError(
		runSource(`
@enum ExprKind { Literal, Add }
@struct Literal {
    kind: ExprKind.Literal;
    value: i64;
}
$a = Literal{ kind: ExprKind.Add, value: 1 };
print(a.value);
`),
		"not assignable",
	);
});

test("struct union Literal | Add with kind narrowing", () => {
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
@func eval(e: Literal | Add) {
    return @switch (e.kind) {
        ExprKind.Literal => { break e.value; },
        ExprKind.Add => { break e.left + e.right; },
    };
}
$a: Literal | Add = Literal{ kind: ExprKind.Literal, value: 42 };
$b: Literal | Add = Add{ kind: ExprKind.Add, left: 3, right: 4 };
print(eval(a));
print(eval(b));
`),
		["42", "7"],
	);
});

test("union field without narrowing is rejected", () => {
	expectError(
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
@func bad(e: Literal | Add) {
    return e.value;
}
print(bad(Literal{ kind: ExprKind.Literal, value: 1 }));
`),
		"not available on all arms",
	);
});

test("union kind @switch must cover all arms", () => {
	expectError(
		runSource(`
@enum ExprKind { Literal, Add, Mul }
@struct Literal {
    kind: ExprKind.Literal;
    value: i64;
}
@struct Add {
    kind: ExprKind.Add;
    left: i64;
    right: i64;
}
@func bad(e: Literal | Add) {
    return @switch (e.kind) {
        ExprKind.Literal => { break e.value; },
    };
}
print(bad(Literal{ kind: ExprKind.Literal, value: 1 }));
`),
		"missing enum variant",
	);
});

test("wrong-arm field after narrowing is rejected", () => {
	expectError(
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
@func bad(e: Literal | Add) {
    return @switch (e.kind) {
        ExprKind.Literal => { break e.left; },
        ExprKind.Add => { break e.left; },
    };
}
print(bad(Literal{ kind: ExprKind.Literal, value: 1 }));
`),
		"does not exist on 'Literal'",
	);
});

test("union @else narrows to remaining arm", () => {
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
@func eval(e: Literal | Add) {
    return @switch (e.kind) {
        ExprKind.Literal => { break e.value; },
        @else => { break e.left + e.right; },
    };
}
print(eval(Literal{ kind: ExprKind.Literal, value: 9 }));
print(eval(Add{ kind: ExprKind.Add, left: 2, right: 5 }));
`),
		["9", "7"],
	);
});

test("un-narrowed shared kind field is allowed", () => {
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
$a: Literal | Add = Literal{ kind: ExprKind.Literal, value: 3 };
$b: Literal | Add = Add{ kind: ExprKind.Add, left: 1, right: 2 };
print(a.kind);
print(b.kind);
`),
		["0", "1"],
	);
});

test("struct outside union is not assignable", () => {
	expectError(
		runSource(`
@enum ExprKind { Literal, Add, Mul }
@struct Literal {
    kind: ExprKind.Literal;
    value: i64;
}
@struct Add {
    kind: ExprKind.Add;
    left: i64;
    right: i64;
}
@struct Mul {
    kind: ExprKind.Mul;
    left: i64;
    right: i64;
}
$a: Literal | Add = Mul{ kind: ExprKind.Mul, left: 2, right: 3 };
print(a.kind);
`),
		"not assignable",
	);
});

test("statement @switch narrows union arms", () => {
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
@func show(e: Literal | Add) {
    @switch (e.kind) {
        ExprKind.Literal => { print(e.value); },
        ExprKind.Add => { print(e.left + e.right); },
    }
}
show(Literal{ kind: ExprKind.Literal, value: 11 });
show(Add{ kind: ExprKind.Add, left: 4, right: 5 });
`),
		["11", "9"],
	);
});
