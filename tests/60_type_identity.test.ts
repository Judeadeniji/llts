/**
 * Type identity: named, field, return, module-qualified, and generic types
 * must stay distinct even when their display strings match.
 */
import { setDefaultTimeout, test } from "bun:test";
import { expectError, expectOutput, runFile, runSource } from "./helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

setDefaultTimeout(60_000);

test("@type chains stay nominal; @alias chains are transparent", () => {
  expectError(
    runSource(`
@type A = i64;
@type B = A;
$a: A = 1;
$b: B = a;
print(b);
`),
    "not assignable",
  );

  expectOutput(
    runSource(`
@type A = i64;
@alias B = A;
$a: A = 1;
$b: B = a;
print(@typeOf(a));
print(@typeOf(b));
print(@typeOf(a) == A);
print(@typeOf(a) == B);
`),
    ["A", "A", "true", "true"],
  );
});

test("same-named structs from different modules are distinct", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_type_identity_"));
  try {
    fs.writeFileSync(
      path.join(dir, "a.lls"),
      `
pub @struct Thing { x: i64; }
pub @func make(): Thing { return Thing { x: 1 }; }
`,
    );
    fs.writeFileSync(
      path.join(dir, "b.lls"),
      `
pub @struct Thing { x: i64; }
pub @func make(): Thing { return Thing { x: 2 }; }
`,
    );

    const bad = path.join(dir, "bad.lls");
    fs.writeFileSync(
      bad,
      `
@const $a = @import("./a.lls");
@const $b = @import("./b.lls");
$a1: a.Thing = a.make();
$b1: b.Thing = a1;
print(b1.x);
pub @func main() {}
`,
    );
    expectError(runFile(bad), "not assignable");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("struct fields preserve the nominal field type", () => {
  expectOutput(
    runSource(`
@type A = i64;
@struct S { x: A; }
$s: S = S { x: @as(A, 1) };
print(@typeOf(s));
print(@typeOf(s.x));
print(s.x);
`),
    ["S", "A", "1"],
  );

  expectError(
    runSource(`
@type A = i64;
@type B = i64;
@struct S { x: A; }
$s: S = S { x: @as(A, 1) };
$v: B = s.x;
print(v);
`),
    "not assignable",
  );
});

test("function returns preserve the nominal return type", () => {
  expectOutput(
    runSource(`
@type A = i64;
@func f(): A { return @as(A, 1); }
$a: A = f();
print(@typeOf(a));
print(a);
`),
    ["A", "1"],
  );

  expectError(
    runSource(`
@type A = i64;
@type B = i64;
@func f(): A { return @as(A, 1); }
$b: B = f();
print(b);
`),
    "not assignable",
  );
});

test("generic type-function instances keep distinct field types", () => {
  expectOutput(
    runSource(`
@func Wrap(T: type): type { return { value: T; }; }
@alias A = Wrap(i64);
@alias B = Wrap(i32);
$a: A = A { value: 1 };
$b: B = B { value: 2 };
print(@typeOf(a.value));
print(@typeOf(b.value));
print(@typeOf(a) == @typeOf(b));
`),
    ["i64", "i32", "false"],
  );

  expectError(
    runSource(`
@func Wrap(T: type): type { return { value: T; }; }
@alias A = Wrap(i64);
@alias B = Wrap(i32);
$a: A = A { value: 1 };
$b: B = a;
print(b.value);
`),
    "not assignable",
  );
});

// Step 18: the debug cache invariant (`verifyTypeCaches`) asserts that every
// recorded display identity has canonical IR, and that displays derive from
// it. A display-only record panics the compiler in Debug builds.
test("debug type-cache invariant holds for typedef, field, and return identities", () => {
  expectOutput(
    runSource(`
@type UserId = i64;
@struct Item { id: UserId; name: string; }
@func make(id: UserId): Item {
    return Item { id: id, name: "x" };
}
$it = make(7);
print(it.id);
print(@typeOf(it.id) == UserId);
`),
    ["7", "true"],
  );
});
