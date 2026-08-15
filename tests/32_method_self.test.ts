/**
 * Method receivers: unannotated `self` is `*T`; calls auto-& from value receivers.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("unannotated method self is *T", () => {
	expectOutput(
		runSource(`
@struct Counter {
    value: i64;
    @func kind(self) {
        return @typeOf(self);
    }
}
$c = Counter { value: 1 };
print(c.kind());
`),
		["*Counter"],
	);
});

test("self: *T accepts value and pointer receivers", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point {
    x: i64;
    @func bump(self: *Point) {
        self.x = self.x + 1;
    }
}
$a = mem.create(0);
$p = Point { x: 1 };
$q = @new(a, Point);
q.x = 10;
p.bump();
q.bump();
print(p.x);
print(q.x);
a.deinit();
`),
		["2", "11"],
	);
});

test("self: T is allowed for non-pointer receivers", () => {
	expectOutput(
		runSource(`
@struct Box {
    n: i64;
    @func get(self: Box) {
        return self.n;
    }
}
$b = Box { n: 7 };
print(b.get());
print((&b).get());
`),
		["7", "7"],
	);
});

test("invalid self annotation is rejected", () => {
	expectError(
		runSource(`
@struct Point {
    x: i64;
    @func bad(self: i64) {
        return self;
    }
}
$p = Point { x: 1 };
print(p.bad());
`),
		"method self must be",
	);
});

test("method arity excludes implicit self", () => {
	expectError(
		runSource(`
@struct Point {
    x: i64;
    @func add(self: *Point, n: i64) {
        self.x = self.x + n;
    }
}
$p = Point { x: 1 };
p.add();
`),
		"expected 1 arguments, got 0",
	);
});
