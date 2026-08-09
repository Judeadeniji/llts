/**
 * Test: Exponent operator ^
 *
 * Before the fix: The compiler ignored the ^ operator because it only checked for "**",
 * even though both map to BinOps.pow. 
 */
import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("^ operator calculates exponent", () => {
	expectOutput(runSource(`
$a = 2 ^ 8;
print(a);
`), ["256"]);
});

test("** operator calculates exponent", () => {
	expectOutput(runSource(`
$a = 3 ** 3;
print(a);
`), ["27"]);
});
