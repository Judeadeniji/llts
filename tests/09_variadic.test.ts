/**
 * Variadic / rest parameters: `@func f(...args)` and `@func f(a, ...rest)`.
 */
import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

test("rest-only packs all arguments into an array", () => {
	expectOutput(
		runSource(`
@func sum(...args) {
    return args[0] + args[1];
}
@func main() {
    print(sum(10, 20));
}
`),
		["30"],
	);
});

test("rest-only with more than two args", () => {
	expectOutput(
		runSource(`
@func third(...args) {
    return args[2];
}
print(third(1, 2, 99));
`),
		["99"],
	);
});

test("named params before rest", () => {
	expectOutput(
		runSource(`
@func join(prefix, ...args) {
    return prefix + args[0] + args[1];
}
print(join(100, 20, 3));
`),
		["123"],
	);
});

test("empty rest packs a zero-length array", () => {
	expectOutput(
		runSource(`
@func argc(...args) {
    return len(args);
}
print(argc());
`),
		["0"],
	);
});

test("rest parameter must be last", () => {
	expectError(
		runSource(`
@func bad(...args, extra) {
    return args[0];
}
print(bad(1, 2));
`),
		"Rest parameter must be the last parameter",
	);
});
