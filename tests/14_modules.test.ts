/**
 * User-module `pub` visibility: private helpers stay in-module;
 * only pub decls are visible to importers.
 */
import { test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { expectError, expectOutput, runFile } from "./helpers";

const ROOT = path.resolve(import.meta.dir, "..");

function withTempModules(
	files: Record<string, string>,
	entryRel: string,
): { dir: string; entry: string } {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_mod_"));
	for (const [rel, src] of Object.entries(files)) {
		const full = path.join(dir, rel);
		fs.mkdirSync(path.dirname(full), { recursive: true });
		fs.writeFileSync(full, src, "utf-8");
	}
	return { dir, entry: path.join(dir, entryRel) };
}

test("pub function can call private helper in the same module", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
@func double(n: int): int {
    return n + n;
}

pub @func answer(): int {
    return double(21);
}
`,
			"main.lls": `
$lib = @import("./lib.lls");
print(lib.answer());
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectOutput(runFile(entry), ["42"]);
});

test("private function is not visible to the importer", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
@func secret(): int {
    return 1;
}

pub @func open(): int {
    return 2;
}
`,
			"main.lls": `
$lib = @import("./lib.lls");
print(lib.secret());
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectError(runFile(entry), "has no export 'secret'");
});

test("private struct is not visible to the importer", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
@struct Hidden {
    x: int;
}

pub @struct Point {
    x: int;
}
`,
			"main.lls": `
$lib = @import("./lib.lls");
$h = lib.Hidden { x: 1 };
print(h.x);
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectError(runFile(entry), "has no export 'Hidden'");
});

test("relative ./ import resolves next to the importer", () => {
	const { entry } = withTempModules(
		{
			"pkg/util.lls": `
pub @func id(n: int): int {
    return n;
}
`,
			"pkg/main.lls": `
$u = @import("./util.lls");
print(u.id(7));
pub @func main() {}
`,
		},
		"pkg/main.lls",
	);
	expectOutput(runFile(entry), ["7"]);
});

test("inline @import with member call and member access", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
pub @const $version = 3;

pub @func answer(): int {
    return 42;
}
`,
			"main.lls": `
print(@import("./lib.lls").answer());
print(@import("./lib.lls").version);
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectOutput(runFile(entry), ["42", "3"]);
});

test("inline @import cannot access private export", () => {
	const { entry } = withTempModules(
		{
			"lib.lls": `
@func secret(): int {
    return 1;
}
`,
			"main.lls": `
print(@import("./lib.lls").secret());
pub @func main() {}
`,
		},
		"main.lls",
	);
	expectError(runFile(entry), "has no export 'secret'");
});

test("existing examples/import_test_main still works", () => {
	expectOutput(runFile(path.join(ROOT, "examples/import_test_main.lls")), [
		"Hello!",
		"Vector3: 10, 20, 30",
	]);
});
