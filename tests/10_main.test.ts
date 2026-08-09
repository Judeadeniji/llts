/**
 * Entry point: a zero-arg `main` is invoked automatically after top-level statements.
 */
import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("main is invoked automatically", () => {
	expectOutput(
		runSource(`
@func main() {
    print(42);
}
`),
		["42"],
	);
});

test("pub main is invoked automatically", () => {
	expectOutput(
		runSource(`
pub @func main() {
    print(7);
}
`),
		["7"],
	);
});

test("top-level statements run before main", () => {
	expectOutput(
		runSource(`
print(1);
@func main() {
    print(2);
}
`),
		["1", "2"],
	);
});

test("without main, only top-level runs", () => {
	expectOutput(
		runSource(`
print(99);
`),
		["99"],
	);
});

test("main can call other functions", () => {
	expectOutput(
		runSource(`
@func add(a, b) {
    return a + b;
}
@func main() {
    print(add(10, 20));
}
`),
		["30"],
	);
});
