/**
 * Region memory: frame rewind + escape errors + @new(allocator, …).
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("returning bare struct literal is immortalized", () => {
	expectOutput(
		runSource(`
@struct Point { x: int; }
@func make() {
    return Point { x: 1 };
}
print(make().x);
`),
		["1"],
	);
});

test("returning nested struct literals is immortalized", () => {
	expectOutput(
		runSource(`
@struct Loc { line: int; }
@struct Point { x: int; loc: Loc; }
@func make() {
    return Point { x: 2, loc: Loc { line: 9 } };
}
$p = make();
print(p.x);
print(p.loc.line);
`),
		["2", "9"],
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

test("returning struct literal that embeds a frame local is a compile error", () => {
	expectError(
		runSource(`
@struct Point { x: int; }
@struct Wrap { p: Point; }
@func make() {
    $p = Point { x: 1 };
    return Wrap { p: p };
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

@func make(a): *Point {
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
