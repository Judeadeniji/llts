/**
 * Test: Compound assignment operators (+=, -=, *=, /=, %=)
 *
 * Before the fix: all compound assignments silently compiled as plain `=`,
 * so `$a += 5` would set $a = 5, discarding the original value.
 */
import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("+= adds to existing value", () => {
	expectOutput(runSource(`
$a = 10;
a += 5;
print(a);
`), ["15"]);
});

test("-= subtracts from existing value", () => {
	expectOutput(runSource(`
$a = 10;
a -= 3;
print(a);
`), ["7"]);
});

test("*= multiplies existing value", () => {
	expectOutput(runSource(`
$a = 4;
a *= 3;
print(a);
`), ["12"]);
});

test("/= divides existing value", () => {
	expectOutput(runSource(`
$a = 20;
a /= 4;
print(a);
`), ["5"]);
});

test("%= applies modulo to existing value", () => {
	expectOutput(runSource(`
$a = 17;
a %= 5;
print(a);
`), ["2"]);
});

test("compound assign in a loop accumulates correctly", () => {
	expectOutput(runSource(`
$sum = 0;
@for (0..5) |i| {
	sum += i;
}
print(sum);
`), ["10"]);
});

test("compound assign on struct field", () => {
	expectOutput(runSource(`
@struct Counter {
	value: int;
}
$c = Counter { value: 10 };
c.value += 5;
print(c.value);
`), ["15"]);
});
