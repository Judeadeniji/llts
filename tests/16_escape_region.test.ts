/**
 * Region memory: frame rewind + escape errors + @new(allocator, …).
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("returning bare struct literal is a compile error", () => {
	expectError(
		runSource(`
@struct Point { x: int; }
@func make() {
    return Point { x: 1 };
}
print(make());
`),
		"escapes its frame region",
	);
});

test("returning local bound to frame struct is a compile error", () => {
	expectError(
		runSource(`
@struct Point { x: int; }
@func make() {
    $p = Point { x: 1 };
    return p;
}
print(make());
`),
		"escapes its frame region",
	);
});

test("@new into Arena may return struct", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");
@struct Point { x: int; y: int; }

@func make(a): Point {
    return @new(a, Point { x: 3, y: 4 });
}

pub @func main() {
    $a = mem.create(64);
    defer a.deinit();
    $p = make(a);
    print(p.x);
    print(p.y);
}
`),
		["3", "4"],
	);
});

test("frame-local struct temps are ok if not returned", () => {
	expectOutput(
		runSource(`
@struct Point { x: int; }
@func sum() {
    $p = Point { x: 7 };
    return p.x;
}
print(sum());
`),
		["7"],
	);
});

test("error return still works (immortal)", () => {
	expectOutput(
		runSource(`
@func boom(): int | error {
    return error("x");
}
$r = boom();
print(@isError(r));
`),
		["true"],
	);
});
