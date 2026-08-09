/**
 * P3: array bounds, shallow VM @const, and scoped bindings.
 */
import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

test("const binding cannot be reassigned at runtime path", () => {
	expectError(
		runSource(`
@func main() {
    @const $x = 1;
    x = 2;
}
`),
		"Cannot reassign to constant",
	);
});

test("const array elements can still be mutated", () => {
	expectOutput(
		runSource(`
@const $arr = [1, 2, 3];
arr[0] = 99;
print(arr[0]);
`),
		["99"],
	);
});

test("inner scope can shadow outer const", () => {
	expectOutput(
		runSource(`
@const $a = 10;
@if (true) {
    @const $a = 20;
    print(a);
}
print(a);
`),
		["20", "10"],
	);
});
