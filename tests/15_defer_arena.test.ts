/**
 * defer (LIFO scope exit) + std.mem.Arena slab allocator.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("defer runs on fallthrough in LIFO order", () => {
	expectOutput(
		runSource(`
@func main() {
    defer print(1);
    defer print(2);
    print(0);
}
`),
		["0", "2", "1"],
	);
});

test("defer block runs multiple statements", () => {
	expectOutput(
		runSource(`
@func main() {
    defer {
        print(2);
        print(1);
    }
    print(0);
}
`),
		["0", "2", "1"],
	);
});

test("defer runs on return", () => {
	expectOutput(
		runSource(`
@func work() {
    defer print("cleanup");
    return 7;
}

print(work());
`),
		["cleanup", "7"],
	);
});

test("defer runs on break from for", () => {
	expectOutput(
		runSource(`
@func main() {
    @for (true) {
        defer print("left");
        break;
    }
    print("after");
}
`),
		["left", "after"],
	);
});

test("defer runs on ? error return", () => {
	expectOutput(
		runSource(`
@func boom(): int | error {
    defer print("def");
    return error("x")?;
}

$r = boom();
print(@isError(r));
`),
		["def", "true"],
	);
});

test("Arena create alloc reset deinit with defer", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");

@func main() {
    $arena = mem.create(32);
    defer arena.deinit();
    $a = arena.alloc(4);
    $b = arena.alloc(4);
    print(b - a);
    arena.reset();
    $c = arena.alloc(4);
    print(c - a);
}
`),
		["4", "0"],
	);
});

test("Arena grows past initial hint like Zig", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");
@func main() {
    $arena = mem.create(2);
    defer arena.deinit();
    $a = arena.alloc(8);
    $b = arena.alloc(8);
    print(a > 0);
    print(b > 0);
}
`),
		["true", "true"],
	);
});

test("Arena create(0) uses default chunk and grows", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");
@func main() {
    $arena = mem.create(0);
    defer arena.deinit();
    $p = arena.alloc(100);
    print(p > 0);
}
`),
		["true"],
	);
});

test("Arena alloc after deinit errors", () => {
	expectError(
		runSource(`
$mem = @import("std/mem");
$arena = mem.create(16);
arena.deinit();
arena.alloc(1);
print(1);
`),
		"deinitialized",
	);
});

test("bump alloc still works", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");
$p = mem.alloc(3);
print(p > 0);
`),
		["true"],
	);
});
