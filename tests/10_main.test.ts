/**
 * Entry point: a public zero-arg `main` is required and invoked after top-level statements.
 */
import { test } from "bun:test";
import { runSource, runSourceAsWritten, expectOutput, expectError } from "./helpers";

test("pub main is invoked automatically", () => {
	expectOutput(
		runSource(`
pub @func main() {
    print(42);
}
`),
		["42"],
	);
});

test("top-level statements run before main", () => {
	expectOutput(
		runSource(`
print(1);
pub @func main() {
    print(2);
}
`),
		["1", "2"],
	);
});

test("without main is a compile error", () => {
	expectError(
		runSourceAsWritten(`
print(99);
`),
		"missing entry point 'main'",
	);
});

test("private main is a compile error", () => {
	expectError(
		runSourceAsWritten(`
@func main() {
    print(1);
}
`),
		"entry point 'main' must be pub",
	);
});

test("main with arguments is a compile error", () => {
	expectError(
		runSource(`
pub @func main(argc) {
    print(argc);
}
`),
		"'main' must take 0 arguments",
	);
});

test("main can call other functions", () => {
	expectOutput(
		runSource(`
@func add(a, b) {
    return a + b;
}
pub @func main() {
    print(add(10, 20));
}
`),
		["30"],
	);
});

test("main returning an error fails with non-zero exit and prints error diagnostic", () => {
	const res = runSource(`
pub @func main() {
    return error("MainError", 500);
}
`);
	expectError(res, "MainError — 500");
	if (res.exitCode === 0) {
		throw new Error("expected non-zero exit code");
	}
	if (!res.stderr.includes("at main (")) {
		throw new Error(`expected main frame in stderr, got:\n${res.stderr}`);
	}
});

test("main propagating an error via ? fails with non-zero exit", () => {
	const res = runSource(`
@func f(fail) {
    @if (fail) {
        return error("TaskFailed");
    }
    return true;
}

pub @func main() {
    f(true)?;
    print("unreachable");
}
`);
	expectError(res, "TaskFailed");
	if (res.exitCode === 0) {
		throw new Error("expected non-zero exit code");
	}
	if (res.stdout.includes("unreachable")) {
		throw new Error(`printed unreachable code:\n${res.stdout}`);
	}
	if (!res.stderr.includes("at main (")) {
		throw new Error(`expected main frame in stderr, got:\n${res.stderr}`);
	}
});

