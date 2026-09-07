import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("list: push, pop, get, set, len", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = list.create(a);
list.push(l, 10);
list.push(l, 20);
list.push(l, 30);
print(list.len(l));
print(list.get(l, 0));
print(list.get(l, 2));
list.set(l, 1, 42);
print(list.get(l, 1));
print(list.pop(l));
print(list.len(l));
`),
		["3", "10", "30", "42", "30", "2"],
	);
});

test("array literal allows trailing comma", () => {
	expectOutput(
		runSource(`
@const $ops = [
    "+", "-", "*",
];
print(len(ops));
print(ops[0]);
print(ops[2]);
`),
		["3", "+", "*"],
	);
});

test("map: set, get, has, delete, size", () => {
	expectOutput(
		runSource(`
@const $map = @import("std/map");
@const $mem = @import("std/mem");
$a = mem.create(0);
$m = map.create(a);
map.set(m, "name", "Alice");
map.set(m, "age", 30);
print(map.size(m));
print(map.get(m, "name"));
print(map.get(m, "age"));
print(map.has(m, "name"));
print(map.has(m, "missing"));
map.delete(m, "name");
print(map.has(m, "name"));
print(map.size(m));
`),
		["2", "Alice", "30", "true", "false", "false", "1"],
	);
});

test("json.stringify handles lists and maps", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
@const $list = @import("std/list");
@const $map = @import("std/map");
@const $mem = @import("std/mem");
$a = mem.create(0);

$l = list.create(a);
list.push(l, 1);
list.push(l, 2);

$m = map.create(a);
map.set(m, "k", "v");

print(json.stringify(l));
print(json.stringify(m));
`),
		["[1,2]", `{"k":"v"}`],
	);
});

test("list storage is reclaimed with arena reset", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = list.create(a);
list.push(l, 1);
list.push(l, 2);
print(list.len(l));
a.reset();
$l2 = list.create(a);
list.push(l2, 9);
print(list.len(l2));
print(list.get(l2, 0));
`),
		["2", "1", "9"],
	);
});

test("list ops fail after arena reset", () => {
	expectError(
		runSource(`
@const $list = @import("std/list");
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = list.create(a);
list.push(l, 1);
a.reset();
_ = list.len(l);
`),
		"arena was reset",
	);
});

test("map ops fail after arena reset", () => {
	expectError(
		runSource(`
@const $map = @import("std/map");
@const $mem = @import("std/mem");
$a = mem.create(0);
$m = map.create(a);
map.set(m, "k", 1);
a.reset();
_ = map.size(m);
`),
		"arena was reset",
	);
});
