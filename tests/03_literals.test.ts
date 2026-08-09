/**
 * Test: Hex, Binary, and Octal literals
 *
 * Before the fix: LiteralExpression cases in the compiler only handled "number", "string", and "boolean".
 * "hex", "binary", and "octal" emitted zero bytecode, silently producing no value on the stack.
 */
import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("hex literal works", () => {
	expectOutput(runSource(`
$a = 0xFF;
print(a);
`), ["255"]);
});

test("binary literal works", () => {
	expectOutput(runSource(`
$a = 0b1010;
print(a);
`), ["10"]);
});

test("octal literal works", () => {
	expectOutput(runSource(`
$a = 0o17;
print(a);
`), ["15"]);
});

test("literals parse into correct values inline", () => {
	expectOutput(runSource(`
print(0x10 + 0b0100 + 0o10);
`), ["28"]);
});
