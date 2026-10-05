import { test } from "bun:test";
import { runSource, runSourceStrict, expectOutput, expectError } from "./helpers";

// ---------------------------------------------------------------------------
// Constant-folding engine: `@comptime` blocks, calls, aggregates and statics
// ---------------------------------------------------------------------------

test("@comptime block generates a constant table", () => {
  expectOutput(runSource(`
@const $POWERS = @comptime {
    $arr = [0, 0, 0, 0, 0];
    $val = 1;
    @for (0..5) |i| {
        arr[i] = val;
        val = val * 2;
    }
    break arr;
};

print(POWERS[0]);
print(POWERS[3]);
print(POWERS[4]);
`), ["1", "8", "16"]);
});

test("@comptime evaluates a pure function call", () => {
  expectOutput(runSource(`
@func square(x: int): int {
    return x * x;
}

@const $SQ = @comptime square(9);
print(SQ);
`), ["81"]);
});

test("@const struct member access folds to a constant", () => {
  expectOutput(runSource(`
@struct Config { port: int; host: string; }
@const $CFG = Config { port: 8080, host: "localhost" };
@const $PORT = CFG.port;
print(PORT);
`), ["8080"]);
});

test("@const len() of a const array folds to a constant", () => {
  expectOutput(runSource(`
@const $ARR = [10, 20, 30, 40];
@const $L = len(ARR);
print(L);
`), ["4"]);
});

test("@const indexing out of bounds is a compile-time error", () => {
  expectError(runSource(`
@const $ARR = [1, 2];
@const $BAD = ARR[5];
print(BAD);
`), "index 5 out of bounds for array of length 2");
});

test("@const division by zero is a compile-time error", () => {
  expectError(runSource(`
@const $BAD = 100 / 0;
print(BAD);
`), "division by zero in constant expression");
});

test("@const array elements are readonly", () => {
  expectError(runSource(`
@const $ARR = [1, 2, 3];
ARR[0] = 99;
`), "Cannot mutate elements of constant 'ARR'");
});

test("@const struct fields are readonly", () => {
  expectError(runSource(`
@struct Point { x: int; y: int; }
@const $P = Point { x: 1, y: 2 };
P.x = 99;
`), "Cannot mutate field of constant 'P'");
});

test("@comptime static errors point at the inner expression", () => {
  const result = runSource(`
@const $BAD = @comptime {
    $arr = [1, 2];
    $i = 5;
    break arr[i];
};
print(BAD);
`);
  expectError(result, "index 5 out of bounds for array of length 2");
  if (!result.stderr.includes("break arr[i];")) {
    throw new Error(
      `Expected the diagnostic to point at the offending line.\nstderr: ${result.stderr}`,
    );
  }
});

// ---------------------------------------------------------------------------
// Data shapes: functions returning structs, branches, enums, tuples, nesting
// ---------------------------------------------------------------------------

test("@comptime evaluates a function that returns a struct", () => {
  expectOutput(runSource(`
@struct Point { x: int; y: int; }
@func make(): Point { return Point { x: 4, y: 5 }; }
@const $P = @comptime make();
print(P.x);
print(P.y);
`), ["4", "5"]);
});

test("@comptime block branches with @if / @else", () => {
  expectOutput(runSource(`
@const $M = @comptime {
    $a = 3;
    $b = 7;
    @if (a > b) { break a; } @else { break b; }
};
print(M);
`), ["7"]);
});

test("@comptime folds an enum variant to its tag", () => {
  expectOutput(runSource(`
@enum Color { Red, Green, Blue }
@const $C = @comptime { break Color.Green; };
print(C);
`), ["1"]);
});

test("@comptime builds a heterogeneous tuple", () => {
  expectOutput(runSource(`
@const $T = @comptime { break [1, \"two\"]; };
print(T[0]);
print(T[1]);
`), ["1", "two"]);
});

test("nested @const struct fields fold through member access", () => {
  expectOutput(runSource(`
@struct Inner { v: int; }
@struct Outer { inner: Inner; name: string; }
@const $O = Outer { inner: Inner { v: 7 }, name: "x" };
@const $V = O.inner.v;
print(V);
`), ["7"]);
});

// ---------------------------------------------------------------------------
// Typechecker integration: `@comptime` results carry real types
// ---------------------------------------------------------------------------

test("strict: @comptime infers a concrete type usable in later constants", () => {
  expectOutput(runSourceStrict(`
@func square(x: int): int { return x * x; }
@const $SQ = @comptime square(9);
@const $N = SQ + 1;
print(N);
`), ["82"]);
});

test("strict: comptime block table and const len() typecheck", () => {
  expectOutput(runSourceStrict(`
@const $POWERS = @comptime {
    $arr = [0, 0, 0, 0, 0];
    $val = 1;
    @for (0..5) |i| {
        arr[i] = val;
        val = val * 2;
    }
    break arr;
};
print(POWERS[4]);
@const $L = len(POWERS);
print(L);
`), ["16", "5"]);
});

test("strict: @comptime in expression position typechecks", () => {
  expectOutput(runSourceStrict(`
@func square(x: int): int { return x * x; }
print(@comptime square(6));
`), ["36"]);
});

test("@comptime block can reference an earlier @const", () => {
  expectOutput(runSource(`
@func square(x: int): int { return x * x; }
@const $N = 3;
@const $SQ = @comptime { break square(N); };
@const $x: int = SQ;
print(x);
`), ["9"]);
});

test("strict: @comptime block referencing an earlier @const typechecks", () => {
  expectOutput(runSourceStrict(`
@func square(x: int): int { return x * x; }
@const $N = 3;
@const $SQ = @comptime { break square(N); };
@const $x: int = SQ;
print(x);
`), ["9"]);
});

test("@comptime block builds a computed aggregate over an earlier @const", () => {
  expectOutput(runSource(`
@func square(x: int): int { return x * x; }
@const $N = 3;
@const $ARR = @comptime {
    $a = [0, 0, 0];
    @for (0..N) |i| { a[i] = i; }
    break a;
};
@const $first: int = ARR[0];
print(first);
@const $SQ = @comptime { break square(N); };
@const $x: int = SQ;
print(x);
`), ["0", "9"]);
});

test("strict: @comptime block builds a computed aggregate over an earlier @const", () => {
  expectOutput(runSourceStrict(`
@func square(x: int): int { return x * x; }
@const $N = 3;
@const $ARR = @comptime {
    $a = [0, 0, 0];
    @for (0..N) |i| { a[i] = i; }
    break a;
};
@const $first: int = ARR[0];
print(first);
@const $SQ = @comptime { break square(N); };
@const $x: int = SQ;
print(x);
`), ["0", "9"]);
});

test("@comptime block locals do not leak into the enclosing scope", () => {
  expectError(runSource(`
@const $R = @comptime {
    $hidden = [1, 2, 3];
    break len(hidden);
};
$x: string = hidden;
print(x);
`), "Unknown identifier 'hidden'");
});

test("regular block locals do not leak into the enclosing scope", () => {
  expectError(runSource(`
@if (true) {
    $hidden = [1, 2, 3];
}
$x: string = hidden;
print(x);
`), "Unknown identifier 'hidden'");
});

test("block-local @const does not mark a same-named outer variable const", () => {
  expectOutput(runSource(`
@struct S { x: int; }
@if (true) {
    @const $c = 5;
    print(c);
}
$c = S { x: 1 };
c.x = 2;
print(c.x);
`), ["5", "2"]);
});

test("strict: type mismatch against a @comptime result is rejected", () => {
  expectError(runSourceStrict(`
@func square(x: int): int { return x * x; }
@const $SQ = @comptime square(9);
@const $bad: string = SQ;
print(bad);
`), "is not assignable to");
});
