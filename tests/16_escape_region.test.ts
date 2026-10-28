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

test("returning local bound to flat scalar struct auto-clones", () => {
  expectOutput(
    runSource(`
@struct Point { x: int; }
@func make() {
    $p = Point { x: 1 };
    return p;
}
print(make().x);
`),
    ["1"],
  );
});

test("returning a param-derived local copy auto-clones (no dangling frame handle)", () => {
  expectOutput(
    runSource(`
@struct S { a: i64; b: i64; }
@func f(s: S): S {
    $out: S = s;
    return out;
}
$s = S { a: 1, b: 2 };
$s2 = f(s);
print(s2.a);
print(s2.b);
`),
    ["1", "2"],
  );
});

test("mutating a param-derived local copy does not touch the caller's value", () => {
  expectOutput(
    runSource(`
@struct S { a: i64; b: i64; }
@func f(s: S): S {
    $out: S = s;
    out.a = 5;
    return out;
}
$s = S { a: 1, b: 2 };
$s2 = f(s);
print(s2.a);
print(s2.b);
print(s.a);
`),
    ["5", "2", "1"],
  );
});

test("rebinding a local from a param via plain assignment is frame-bound and clones on return", () => {
  expectOutput(
    runSource(`
@struct S { a: i64; b: i64; }
@func f(s: S): S {
    $out: S = s;
    out = s;
    out.b = 9;
    return out;
}
$s = S { a: 1, b: 2 };
$s2 = f(s);
print(s2.b);
print(s.b);
`),
    ["9", "2"],
  );
});

test("returning a param-derived local copy of a nested value-struct deep-clones", () => {
  expectOutput(
    runSource(`
@struct Inner { x: i64; }
@struct Outer { i: Inner; y: i64; }
@func f(o: Outer): Outer {
    $out: Outer = o;
    out.y = 9;
    return out;
}
$o = Outer { i: Inner { x: 1 }, y: 2 };
$o2 = f(o);
print(o2.i.x);
print(o2.y);
print(o.y);
`),
    ["1", "9", "2"],
  );
});

test("returning a param-derived local copy with slice fields is a compile error", () => {
  expectError(
    runSource(`
@struct Box { items: []i64; len: i64; }
@func f(b: Box): Box {
    $out: Box = b;
    return out;
}
$b = Box { items: [1, 2], len: 2 };
$b2 = f(b);
print(b2.len);
`),
    "value escapes its frame region",
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
    $p = @new(a, Point);
    p.x = 3;
    p.y = 4;
    return p;
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

test("@new into a function-local arena must not escape (local binding)", () => {
  expectError(
    runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }

@func make(): *Box {
    $a = mem.create(0);
    $p = @new(a, Box);
    p.n = 1;
    return p;
}

pub @func main() {
    print(make().n);
}
`),
    "escapes its arena region",
  );
});

test("@new into a function-local arena must not escape (direct return)", () => {
  expectError(
    runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }

@func make(): *Box {
    $a = mem.create(0);
    $p = @new(a, Box);
    p.n = 1;
    return p;
}

pub @func main() {
    print(make().n);
}
`),
    "escapes its arena region",
  );
});

test("@new into a parameter arena may escape", () => {
  expectOutput(
    runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }

@func make(a: mem.Arena): *Box {
    $p = @new(a, Box);
    p.n = 7;
    return p;
}

pub @func main() {
    $a = mem.create(0);
    defer a.deinit();
    print(make(a).n);
}
`),
    ["7"],
  );
});

test("@new into a module-level arena may escape", () => {
  expectOutput(
    runSource(`
$mem = @import("std/mem");
@struct Box { n: int; }
$heap = mem.create(0);

@func make(): *Box {
    $p = @new(heap, Box);
    p.n = 9;
    return p;
}

pub @func main() {
    print(make().n);
}
`),
    ["9"],
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
