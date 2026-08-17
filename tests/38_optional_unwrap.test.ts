import { test } from "bun:test";
import { expectOutput, runSource } from "./helpers";

test("@if optional unwrap", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $maybe: ?int = 42;
    @if (maybe) |v| {
        print(v);
    }
}
`),
		["42"],
	);
});

test("@if optional unwrap null", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $maybe: ?int = null;
    $x = 0;
    @if (maybe) |v| {
        x = v;
    } @else {
        x = 99;
    }
    print(x);
}
`),
		["99"],
	);
});

test("@for optional unwrapping (while-let)", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $arr: []int = [10, 20, 30];
    $i: int = 0;
    @for (@if (i < 3) { break arr[i]; } @else { break null; }) |v| {
        print(v);
        i = i + 1;
    }
    print(i);
}
`),
		["10", "20", "30", "3"],
	);
});

test("@for iterates over string and print characters", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $s = "abc";
    @for (s) |c| {
        __printLn("{c}", c);
    }
}
`),
		["a", "b", "c"],
	);
});

test("@for iterates over string variables and slice variables", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $s: string = "yo";
    @for (s) |c| {
        __printLn("{c}", c);
    }

    $arr: []int = [9, 8];
    @for (arr) |n| {
        print(n);
    }
}
`),
		["y", "o", "9", "8"],
	);
});

import { expectError } from "./helpers";

test("@if capture with multiple captures errors", () => {
	expectError(
		runSource(`
pub @func main() {
    $maybe: ?int = 42;
    @if (maybe) |v, err| {
        print(v);
    }
}
`),
		"Expected \"|\" after pipe capture",
	);
});

test("@if capture on non-optional is allowed", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $val: int = 42;
    @if (val) |v| {
        print(v);
    }
}
`),
		["42"],
	);
});

test("@for optional unwrapping with multiple captures errors", () => {
	expectError(
		runSource(`
pub @func main() {
    $maybe: ?int = 42;
    @for (maybe) |v, idx| {
        print(v);
    }
}
`),
		"Optional while-loop only supports 1 capture",
	);
});

test("@for iterates over string with index", () => {
	expectOutput(
		runSource(`
pub @func main() {
    $s = "abc";
    @for (s) |c, idx| {
        print(idx);
    }
}
`),
		["0", "1", "2"],
	);
});
