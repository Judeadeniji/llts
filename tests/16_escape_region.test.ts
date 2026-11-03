/** Region memory: frame rewind and escape errors. */
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
