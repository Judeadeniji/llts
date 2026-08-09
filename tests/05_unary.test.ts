/**
 * Test: Unary +
 *
 * Before the fix: Unary + parsed correctly but the compiler had no case for it,
 * so it emitted zero bytecode (no-op), leaving no value on the stack.
 */
import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("unary + does nothing but leaves value on stack", () => {
	expectOutput(runSource(`
$a = 5;
$b = +a;
print(b);
`), ["5"]);
});

test("unary + converts negative back to positive? No, + is an identity operator.", () => {
	expectOutput(runSource(`
$a = -5;
$b = +a;
print(b);
`), ["-5"]);
});

test("unary - negates", () => {
	expectOutput(runSource(`
$a = 5;
print(-a);
`), ["-5"]);
});
