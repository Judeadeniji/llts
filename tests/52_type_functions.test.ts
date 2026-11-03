import { test } from "bun:test";
import { expectError, expectOutput, runFile, runSource } from "./helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

test("type functions: usable in annotations, params, fields and @alias", () => {
  expectOutput(
    runSource(`
@func Opt(T: type): type { return ?T; }
@func Id(T: type): type { return T; }
@struct Holder { v: Id(u16); w: i64; }
@alias OI = Opt(i64);
@func take(o: Opt(i64)): i64 {
    @if (o) |v| { return v; }
    return 0;
}
pub @func main() {
    $x: Opt(i64) = null;
    print(@typeOf(x));
    $y: OI = 5;
    print(@typeOf(y));
    $h = Holder { v: 300, w: 2 };
    print(@typeOf(h.v));
    print(h.v);
    print(take(42));
    print(take(null));
    print(@sizeOf(Opt(u8)));
}
`),
    ["?i64", "?i64", "u16", "300", "42", "0", "1"],
  );
});

test("type functions: @if on types, nesting, and type values", () => {
  expectOutput(
    runSource(`
@func Opt(T: type): type { return ?T; }
@func OptOpt(T: type): type { return Opt(T); }
@func Wide(T: type): type {
    @if (T == u8) {
        return u16;
    }
    return T;
}
pub @func main() {
    print(Wide(u8));
    print(Wide(i32));
    print(OptOpt(u8));
    print(Opt([]u8) == ?[]u8);
    print(Wide(u8) == u16);
}
`),
    ["u16", "i32", "?u8", "true", "true"],
  );
});

test("generic functions: monomorphized per type argument", () => {
  expectOutput(
    runSource(`
@func max(T: type, a: T, b: T): T {
    @if (a > b) { return a; }
    return b;
}
@func max3(T: type, a: T, b: T, c: T): T {
    return max(T, max(T, a, b), c);
}
pub @func main() {
    print(max(i64, 3, 9));
    print(max(f64, 2.5, 1.5));
    print(max3(i64, 4, 11, 7));
    $m = max(u8, 1, 2);
    print(@typeOf(m));
}
`),
    ["9", "2.5", "11", "u8"],
  );
});

test("generic functions: type parameter is a type value in the body", () => {
  expectOutput(
    runSource(`
@func describe(T: type, v: T) {
    print(T);
    print(@sizeOf(T));
    $local: T = v;
    print(local);
}
pub @func main() {
    describe(u8, 200);
    describe(i64, 5);
}
`),
    ["u8", "1", "200", "i64", "8", "5"],
  );
});

test("generic functions and type functions across modules", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_generics_"));
  try {
    fs.writeFileSync(
      path.join(dir, "lib.lls"),
      `
pub @func Opt(T: type): type { return ?T; }
pub @func pick(T: type, c: bool, a: T, b: T): T {
    @if (c) { return a; }
    return b;
}
`,
    );
    fs.writeFileSync(
      path.join(dir, "main.lls"),
      `
@const $lib = @import("./lib.lls");
pub @func main() {
    print(lib.pick(i64, true, 1, 2));
    print(lib.pick(f64, false, 1.5, 2.5));
    $o: lib.Opt(i64) = null;
    print(@typeOf(o));
    print(lib.Opt(u8));
}
`,
    );
    expectOutput(runFile(path.join(dir, "main.lls")), [
      "1",
      "2.5",
      "?i64",
      "?u8",
    ]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("generic functions: a value where a type is expected is rejected", () => {
  expectError(
    runSource(`
@func max(T: type, a: T, b: T): T { return a; }
pub @func main() { print(max(5, 1, 2)); }
`),
    "Argument 1 of 'max' must be a type",
  );
});

test("generic functions: value arguments are checked against the instance", () => {
  expectError(
    runSource(`
@func max(T: type, a: T, b: T): T { return a; }
pub @func main() { print(max(i64, 1, true)); }
`),
    "argument 3 of 'max'",
  );
});

test("type functions: must return a type", () => {
  expectError(
    runSource(`
@func Bad(T: type): type { return 5; }
pub @func main() { $x: Bad(i64) = 1; }
`),
    "Type function 'Bad' must return a type",
  );
});

test("type functions: only type parameters are allowed", () => {
  expectError(
    runSource(`
@func Bad(T: type, n: i64): type { return T; }
pub @func main() { }
`),
    "Type function 'Bad' may only take 'type' parameters ('n' is not)",
  );
});

test("generic functions: cannot be used as values", () => {
  expectError(
    runSource(`
@func max(T: type, a: T, b: T): T { return a; }
pub @func main() { $f = max; }
`),
    "Generic function 'max' cannot be used as a value",
  );
});

test("generic functions: struct methods cannot take type parameters", () => {
  expectError(
    runSource(`
@struct S { n: i64; @func get(self: S, T: type): i64 { return self.n; } }
pub @func main() { $s = S { n: 1 }; }
`),
    "Struct methods cannot take type parameters yet ('get')",
  );
});

test("generic functions: unbounded instantiation is cut off", () => {
  expectError(
    runSource(`
@func rec(T: type, n: i64): i64 { return rec([]T, n); }
pub @func main() { print(rec(i64, 1)); }
`),
    "Generic instantiation too deep",
  );
});
