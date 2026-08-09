/**
 * Test: OP_SET_PROPERTY VM handler
 *
 * Before the fix: setting a property on an object via the dynamic path
 * (non-struct-offset assignment) would hit an unhandled opcode in the VM,
 * corrupting the instruction pointer silently.
 *
 * After the fix: OP_SET_PROPERTY writes the value to the JS object directly.
 */
import { test, } from "bun:test";
import { expectOutput, runSource } from "./helpers";

test("dynamic property set and get roundtrip", () => {
	const result = runSource(`
@const $std = @import("std/index");
$obj = std.debug;
obj.x = 42;
print(obj.x);
`);
	expectOutput(result, ["42"]);
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
