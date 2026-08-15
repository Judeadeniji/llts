/**
 * `const` expression modifier — keep singleton / deep literal types.
 */
import { test } from "bun:test";
import { expectOutput, runSource } from "./helpers";

test('const "x" has type "x", not [1]byte', () => {
	expectOutput(
		runSource(`
print(@typeOf("x"));
print(@typeOf(const "x"));
$a = const "x";
print(@typeOf(a));
`),
		["[1]byte", '"x"', '"x"'],
	);
});

test("@const binding infers literal types", () => {
	expectOutput(
		runSource(`
@const $k = "y";
print(@typeOf(k));
@const $n = 3;
print(@typeOf(n));
`),
		['"y"', "3"],
	);
});

test("const array becomes a deep literal tuple", () => {
	expectOutput(
		runSource(`
$p = const [1, "hi"];
print(@typeOf(p));
print(p.0);
print(p.1);
`),
		['[1, "hi"]', "1", "hi"],
	);
});

test("tuple with const string element", () => {
	expectOutput(
		runSource(`
$p = [1, const "hi"];
print(@typeOf(p));
`),
		['[i64, "hi"]'],
	);
});
