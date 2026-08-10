/**
 * Value-producing @if / @switch / labeled blocks via explicit `break <value>`.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("value @if assigns break payloads", () => {
	expectOutput(
		runSource(`
$x = @if (true) {
    break 1;
} @else {
    break 2;
};
print(x);
`),
		["1"],
	);
});

test("value @if requires @else", () => {
	expectError(
		runSource(`
$x = @if (true) {
    break 1;
};
`),
		"requires @else",
	);
});

test("value @if arm must break a value", () => {
	expectError(
		runSource(`
$x = @if (true) {
    print(1);
} @else {
    break 2;
};
`),
		"must `break` a value",
	);
});

test("@else @if chain produces a value", () => {
	expectOutput(
		runSource(`
$n = 2;
$x = @if (n == 1) {
    break 10;
} @else @if (n == 2) {
    break 20;
} @else {
    break 30;
};
print(x);
`),
		["20"],
	);
});

test("labeled block break :label value", () => {
	expectOutput(
		runSource(`
$z = blk: {
    break :blk 42;
};
print(z);
`),
		["42"],
	);
});

test("labeled block with locals and expression payload", () => {
	expectOutput(
		runSource(`
$sum = compute: {
    $a = 10;
    $b = 32;
    break :compute a + b;
};
print(sum);
`),
		["42"],
	);
});

test("labeled block early exit via nested @if", () => {
	expectOutput(
		runSource(`
$abs = absv: {
    $n = 0 - 7;
    @if (n < 0) {
        break :absv 0 - n;
    }
    break :absv n;
};
print(abs);
`),
		["7"],
	);
});

test("nested labeled blocks break to the named target", () => {
	expectOutput(
		runSource(`
$v = outer: {
    $inner = inner: {
        break :inner 1;
    };
    break :outer inner + 2;
};
print(v);
`),
		["3"],
	);
});

test("break :outer skips remaining inner statements", () => {
	expectOutput(
		runSource(`
$v = outer: {
    inner: {
        break :outer 99;
    }
    break :outer 0;
};
print(v);
`),
		["99"],
	);
});

test("labeled block result can be type-annotated", () => {
	expectOutput(
		runSource(`
$flag: bool = check: {
    break :check true;
};
print(flag);
print(@typeOf(flag));
`),
		["true", "bool"],
	);
});

test("labeled block must break a value", () => {
	expectError(
		runSource(`
$x = blk: {
    print(1);
};
`),
		"must `break` a value",
	);
});

test("break to unknown block label errors", () => {
	expectError(
		runSource(`
$x = blk: {
    break :missing 1;
};
`),
		"Cannot find value expression with label",
	);
});

test("unlabeled block cannot be a value expression", () => {
	expectError(
		runSource(`
$x = { break 1; };
`),
		"requires a label",
	);
});

test("value @switch with multi-match and @else", () => {
	expectOutput(
		runSource(`
@enum Color { Red, Green, Blue }
$c = @switch (Color.Blue) {
    Color.Red => { break 1; },
    Color.Green, Color.Blue => { break 2; },
    @else => { break 0; },
};
print(c);
`),
		["2"],
	);
});

test("statement @switch still works", () => {
	expectOutput(
		runSource(`
@switch (1) {
    0 => { print(0); },
    1 => { print(9); },
    @else => { print(-1); },
}
`),
		["9"],
	);
});

test("value @switch requires @else", () => {
	expectError(
		runSource(`
$x = @switch (1) {
    1 => { break 1; },
};
`),
		"requires @else",
	);
});

test("break with value outside value context errors", () => {
	expectError(
		runSource(`
@func main() {
    break 1;
}
main();
`),
		"break with value",
	);
});
