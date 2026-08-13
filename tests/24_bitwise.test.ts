/**
 * Bitwise operators: &, |, ~ (XOR / NOT), <<, >>, and compounds.
 * `^` / `**` remain exponentiation.
 */
import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

test("bitwise AND OR XOR", () => {
	expectOutput(
		runSource(`
print(0b1100 & 0b1010);
print(0b1100 | 0b1010);
print(0b1100 ~ 0b1010);
`),
		["8", "14", "6"],
	);
});

test("bitwise NOT and shifts", () => {
	expectOutput(
		runSource(`
print(~0);
print(1 << 4);
print(32 >> 3);
print(-8 >> 1);
`),
		["-1", "16", "4", "-4"],
	);
});

test("bitwise compounds", () => {
	expectOutput(
		runSource(`
$a = 0b1111;
a &= 0b1100;
print(a);
a |= 0b0011;
print(a);
a ~= 0b0101;
print(a);
$b = 1;
b <<= 3;
print(b);
b >>= 1;
print(b);
`),
		["12", "15", "10", "8", "4"],
	);
});

test("^ remains power, not XOR", () => {
	expectOutput(
		runSource(`
print(2 ^ 8);
print(2 ** 3);
print(7 ~ 3);
`),
		["256", "8", "4"],
	);
});

test("precedence: shifts bind tighter than add; compare tighter than bitwise", () => {
	expectOutput(
		runSource(`
print(1 + 2 << 2);
print(1 << 2 + 1);
print(1 | 2 == 3);
print((1 | 2) == 3);
`),
		["12", "8", "1", "true"],
	);
});

test("for capture |i| still works with bitwise |", () => {
	expectOutput(
		runSource(`
$sum = 0;
@for (0..4) |i| {
	sum = sum | (1 << i);
}
print(sum);
`),
		["15"],
	);
});

test("type union T | error still parses", () => {
	expectOutput(
		runSource(`
@func f(): int | error {
	return 1;
}
print(f());
`),
		["1"],
	);
});

test("bitwise rejects floats", () => {
	expectError(runSource(`print(1.5 & 2);`), "integers");
});

test("shift amount out of range", () => {
	expectError(runSource(`print(1 << 64);`), "Shift amount out of range");
});
