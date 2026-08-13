import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("list: push, pop, get, set, len", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
$l = list.create();
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

test("map: set, get, has, delete, size", () => {
	expectOutput(
		runSource(`
@const $map = @import("std/map");
$m = map.create();
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

$l = list.create();
list.push(l, 1);
list.push(l, 2);

$m = map.create();
map.set(m, "k", "v");

print(json.stringify(l));
print(json.stringify(m));
`),
		["[1,2]", `{"k":"v"}`],
	);
});
