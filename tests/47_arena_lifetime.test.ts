/**
 * Phase 4.1: Runtime arena lifetime traps.
 *
 * Handles into arena memory stamp the owning arena and the generation at
 * allocation time. Accessing them after the arena is `deinit`ed or `reset`
 * must trap deterministically instead of reading recycled memory.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// --- use-after-deinit ------------------------------------------------------

test("use-after-deinit on an arena struct field traps", () => {
	expectError(
		runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }
$arena = mem.create(0);
$p = @new(arena, Box { n: 1 });
arena.deinit();
print(p.n);
`),
		"arena is deinitialized",
	);
});

test("use-after-deinit on an arena []byte traps", () => {
	expectError(
		runSource(`
$mem = @import("std/mem");
$arena = mem.create(0);
$b = @new(arena, []byte, 4);
b[0] = 65;
arena.deinit();
print(b[0]);
`),
		"arena is deinitialized",
	);
});

// --- use-after-reset -------------------------------------------------------

test("use-after-reset on an arena struct field traps", () => {
	expectError(
		runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }
$arena = mem.create(0);
$p = @new(arena, Box { n: 7 });
arena.reset();
print(p.n);
`),
		"arena was reset",
	);
});

test("use-after-reset on an arena []int traps", () => {
	expectError(
		runSource(`
$mem = @import("std/mem");
$arena = mem.create(0);
$xs = @new(arena, []int, 3);
xs[0] = 5;
arena.reset();
print(xs[0]);
`),
		"arena was reset",
	);
});

// --- valid lifetimes still work -------------------------------------------

test("arena memory is usable before deinit", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }
$arena = mem.create(0);
$p = @new(arena, Box { n: 42 });
print(p.n);
arena.deinit();
`),
		["42"],
	);
});

test("a fresh allocation after reset is valid", () => {
	expectOutput(
		runSource(`
$mem = @import("std/mem");
$arena = mem.create(0);
$p = @new(arena, []int, 2);
p[0] = 1;
arena.reset();
$q = @new(arena, []int, 2);
q[0] = 99;
print(q[0]);
arena.deinit();
`),
		["99"],
	);
});

test("frame and immortal arrays are unaffected by arena state", () => {
	expectOutput(
		runSource(`
$a = [1, 2, 3];
print(a[1]);
$mem = @import("std/mem");
$arena = mem.create(0);
$p = @new(arena, []int, 2);
p[0] = 7;
arena.deinit();
print(a[2]);
`),
		["2", "3"],
	);
});
