import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("type values: @typeOf in local annotations and composites", () => {
  expectOutput(
    runSource(`
pub @func main() {
    $x: i64 = 42;
    $y: @typeOf(x) = 5;
    $p: ?@typeOf(x) = null;
    $arr: []@typeOf(x) = [1, 2, 3];
    $u: @typeOf(x) | f64 = 1.5;
    print(@typeOf(y));
    print(@typeOf(p));
    print(@typeOf(arr));
    print(@typeOf(u));
}
`),
    ["i64", "?i64", "[]i64", "i64 | f64"],
  );
});

test("type values: @typeOf in params and return types", () => {
  expectOutput(
    runSource(`
@func twice(a: i64, b: @typeOf(a)): @typeOf(a) {
    return a + b;
}
pub @func main() {
    $r = twice(1, 2);
    print(r);
    print(@typeOf(r));
}
`),
    ["3", "i64"],
  );
});

test("type values: @alias and struct fields from a global's type", () => {
  expectOutput(
    runSource(`
$g: u8 = 7;
@alias G = @typeOf(g);
@struct Holder { v: @typeOf(g); w: i64; }
pub @func main() {
    $h: G = 3;
    print(@typeOf(h));
    print(@sizeOf(G));
    print(@sizeOf(Holder));
    $s = Holder { v: 1, w: 2 };
    print(@typeOf(s.v));
}
`),
    ["u8", "1", "16", "u8"],
  );
});

test("type values: @typeOf of a type is `type`", () => {
  expectOutput(
    runSource(`
@struct Point { x: i64; y: i64; }
pub @func main() {
    $x: i64 = 1;
    print(@typeOf(i64));
    print(@typeOf(Point));
    print(@typeOf(@typeOf(x)));
}
`),
    ["type", "type", "type"],
  );
});

test("type values: @sizeOf accepts type values", () => {
  expectOutput(
    runSource(`
@struct Point { x: i64; y: i64; }
pub @func main() {
    $x: i32 = 1;
    $p = Point { x: 1, y: 2 };
    print(@sizeOf(@typeOf(x)));
    print(@sizeOf(@typeOf(p)));
    print(@sizeOf(Point));
}
`),
    ["4", "16", "16"],
  );
});

test("type values: == and != fold at compile time", () => {
  expectOutput(
    runSource(`
$g: u8 = 7;
pub @func main() {
    $x: i64 = 42;
    print(@typeOf(x) == i64);
    print(@typeOf(x) != i64);
    print(@typeOf(g) == u8);
    print(@typeOf(x) == @typeOf(g));
    @if (@typeOf(x) == i64) { print("is i64"); }
}
`),
    ["true", "false", "true", "false", "is i64"],
  );
});

test("type values: distinct @type names compare nominally", () => {
  expectOutput(
    runSource(`
@type Meters = i64;
pub @func main() {
    $m: Meters = @as(Meters, 3);
    print(@typeOf(m) == Meters);
    print(@typeOf(m) == i64);
}
`),
    ["true", "false"],
  );
});

test("type values: @as and @new accept type values", () => {
  expectOutput(
    runSource(`
@const $mem = @import("std/mem");
@struct N { v: i64; }
$g: u8 = 7;
pub @func main() {
    $c = @as(@typeOf(g), 9);
    print(@typeOf(c));
    $a = mem.create(0);
    $proto = N { v: 1 };
    $p = @new(a, @typeOf(proto));
    print(@typeOf(p));
}
`),
    ["u8", "*N"],
  );
});

test("type values: @typeOf never evaluates its operand", () => {
  expectOutput(
    runSource(`
@func noisy(): i64 {
    print("side effect");
    return 1;
}
pub @func main() {
    print(@typeOf(noisy()));
    print("done");
}
`),
    ["i64", "done"],
  );
});

test("type values: @typeOf of an enum variant is the enum", () => {
  expectOutput(
    runSource(`
@enum Color { Red, Blue }
pub @func main() {
    print(@typeOf(Color.Blue));
}
`),
    ["Color"],
  );
});

test("type values: @typeOf sees flow narrowing", () => {
  expectOutput(
    runSource(`
pub @func main() {
    $v: ?i64 = 3;
    @if (v != null) {
        print(@typeOf(v));
    }
}
`),
    ["i64"],
  );
});

test("type values: storing a type value is rejected", () => {
  expectError(
    runSource(`
pub @func main() {
    $x: i64 = 1;
    $t = @typeOf(x);
}
`),
    "Cannot use a 'type' value as",
  );
});

test("type values: returning a type value is rejected", () => {
  expectError(
    runSource(`
@func f(x: i64) {
    return @typeOf(x);
}
pub @func main() { f(1); }
`),
    "Cannot use a 'type' value as",
  );
});

test("type values: comparing a type with a string is rejected", () => {
  expectError(
    runSource(`
pub @func main() {
    $x: i64 = 1;
    print(@typeOf(x) == "i64");
}
`),
    "Cannot compare 'type' with a value of type",
  );
});

test("type values: arithmetic on types is rejected", () => {
  expectError(
    runSource(`
pub @func main() {
    $x: i64 = 1;
    print(@typeOf(x) + i64);
}
`),
    "not defined on 'type' values",
  );
});

test("type values: a value in type position is rejected", () => {
  expectError(
    runSource(`
pub @func main() {
    $x: @sizeOf(i64) = 1;
}
`),
    "Expected a type, found a value of type",
  );
});

test("type values: untyped global in a declaration needs an annotation", () => {
  expectError(
    runSource(`
@func make(): i64 { return 1; }
$g = make();
@struct Holder { v: @typeOf(g); }
pub @func main() { print(g); }
`),
    "Cannot resolve this type here",
  );
});

test("type values: unknown @typeOf operand is rejected", () => {
  expectError(
    runSource(`
pub @func main() {
    print(@typeOf(nope));
}
`),
    "Unknown identifier 'nope'",
  );
});
