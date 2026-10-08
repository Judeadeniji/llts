/**
 * Test: OP_SET_PROPERTY VM handler
 *
 * Before the fix: setting a property on an object via the dynamic path
 * (non-struct-offset assignment) would hit an unhandled opcode in the VM,
 * corrupting the instruction pointer silently.
 *
 * After the fix: OP_SET_PROPERTY writes the value to the JS object directly.
 */
import { test } from "bun:test";
import { expectOutput, expectError, runSource } from "./helpers";

test("rejects mutating imported module namespace", () => {
	const result = runSource(`
@const $std = @import("std/index");
$obj = std.fmt;
obj.x = 42;
print(obj.x);
`);
	expectError(result, "Cannot assign field 'x' on non-struct target");
});

test("rejects direct assignment to imported module property", () => {
	const result = runSource(`
@const $std = @import("std/index");
std.fmt.x = 42;
`);
	expectError(result, "Cannot assign to member 'x' of imported module");
});

test("rejects dynamic property set on non-struct", () => {
	const result = runSource(`
$x = 42;
x.foo = 1;
`);
	expectError(result, "cannot assign field 'foo'");
});

test("rejects assignment to undeclared struct field", () => {
	const result = runSource(`
@struct Counter { value: int; }
$c = Counter { value: 0 };
c.unknown_field = 42;
`);
	expectError(result, "Field 'unknown_field' does not exist on 'Counter'");
});

test("property set inside function", () => {
	const result = runSource(`
@struct Counter {
	value: int;

	@func increment(self) {
		self.value = self.value + 1;
		return self;
	}
}

$c = Counter { value: 0 };
c.increment();
c.increment();
c.increment();
print(c.value);
`);
	expectOutput(result, ["3"]);
});
