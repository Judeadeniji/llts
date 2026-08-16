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

test("self: T mutations do not alias the caller", () => {
	expectOutput(
		runSource(`
@struct Point {
    x: i64;
    y: i64;
    @func len2(self: Point): i64 {
        $res = self.x * self.x + self.y * self.y;
        self.x = self.y = 0;
        return res;
    }
}
$p = Point { x: 3, y: 4 };
print(p.len2());
print(p.x, p.y);
`),
		["25", "3 4"],
	);
});

test("self: T @typeOf is T not *T", () => {
	expectOutput(
		runSource(`
@struct Box {
    n: i64;
    @func kind(self: Box) {
        return @typeOf(self);
    }
}
$b = Box { n: 1 };
print(b.kind());
`),
		["Box"],
	);
});

test("self: T via &receiver still clones (auto-deref)", () => {
	expectOutput(
		runSource(`
@struct Point {
    x: i64;
    @func zero(self: Point) {
        self.x = 0;
        return self.x;
    }
}
$p = Point { x: 9 };
print((&p).zero());
print(p.x);
`),
		["0", "9"],
	);
});

test("self: T repeated calls each get a fresh copy", () => {
	expectOutput(
		runSource(`
@struct Counter {
    n: i64;
    @func bumpCopy(self: Counter) {
        self.n = self.n + 1;
        return self.n;
    }
}
$c = Counter { n: 10 };
print(c.bumpCopy());
print(c.bumpCopy());
print(c.n);
`),
		["11", "11", "10"],
	);
});

test("self: *T still aliases while self: T on same type does not", () => {
	expectOutput(
		runSource(`
@struct Point {
    x: i64;
    @func bump(self: *Point) {
        self.x = self.x + 1;
    }
    @func bumpCopy(self: Point) {
        self.x = self.x + 1;
        return self.x;
    }
}
$p = Point { x: 1 };
print(p.bumpCopy());
print(p.x);
p.bump();
print(p.x);
print(p.bumpCopy());
print(p.x);
`),
		["2", "1", "2", "3", "2"],
	);
});

test("self: T on @new heap object does not mutate the original", () => {
	expectOutput(
		runSource(`
@const $mem = @import("std/mem");
@struct Point {
    x: i64;
    @func zero(self: Point) {
        self.x = 0;
        return self.x;
    }
}
$a = mem.create(0);
$q = @new(a, Point);
q.x = 5;
print(q.zero());
print(q.x);
a.deinit();
`),
		["0", "5"],
	);
});

test("self: T copy sees caller values at call time", () => {
	expectOutput(
		runSource(`
@struct Point {
    x: i64;
    @func get(self: Point) {
        return self.x;
    }
}
$p = Point { x: 1 };
print(p.get());
p.x = 42;
print(p.get());
`),
		["1", "42"],
	);
});

test("self: T shallow-copies nested struct handles", () => {
	// Nested structs are handles: cloning Outer copies the handle, so
	// mutating nested fields through by-value self still aliases the inner object.
	expectOutput(
		runSource(`
@struct Inner {
    n: i64;
}
@struct Outer {
    inner: Inner;
    @func bumpInner(self: Outer) {
        self.inner.n = self.inner.n + 1;
        return self.inner.n;
    }
}
$o = Outer { inner: Inner { n: 3 } };
print(o.bumpInner());
print(o.inner.n);
`),
		["4", "4"],
	);
});

test("self: T mutates only scalar fields of the copy when nested is untouched", () => {
	expectOutput(
		runSource(`
@struct Inner {
    n: i64;
}
@struct Outer {
    tag: i64;
    inner: Inner;
    @func retag(self: Outer) {
        self.tag = 99;
        return self.tag;
    }
}
$o = Outer { tag: 1, inner: Inner { n: 7 } };
print(o.retag());
print(o.tag, o.inner.n);
`),
		["99", "1 7"],
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

test("self typed as a different struct is rejected", () => {
	expectError(
		runSource(`
@struct A {
    x: i64;
}
@struct B {
    y: i64;
    @func bad(self: A) {
        return self.x;
    }
}
$b = B { y: 1 };
print(b.bad());
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
