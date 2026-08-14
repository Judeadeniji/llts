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
