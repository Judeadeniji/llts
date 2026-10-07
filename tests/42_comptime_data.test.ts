import { test } from "bun:test";
import { runSource, runSourceStrict, runSourceWithEnv, runSourceWithFlags, expectOutput, expectError } from "./helpers";

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

// ---------------------------------------------------------------------------
// `return` inside a `@comptime` block yields the block's value, including from
// nested `@if` / `@for` / `@switch` bodies, where it is a non-local exit.
// ---------------------------------------------------------------------------

test("@comptime block yields its value via return", () => {
  expectOutput(runSource(`
@const $R = @comptime { return 41; };
print(R);
`), ["41"]);
});

test("strict: @comptime block yielding via return infers a concrete type", () => {
  expectOutput(runSourceStrict(`
@const $R = @comptime { return 41; };
@const $N: int = R + 1;
print(N);
`), ["42"]);
});

test("return inside @if / @for bodies propagates out of a @comptime block", () => {
  expectOutput(runSource(`
@const $B = @comptime {
    $a = 3;
    $b = 7;
    @if (a > b) { return a; } @else { return b; }
};
print(B);
@const $N = @comptime {
    @for (0..5) |i| {
        @if (i == 3) { return i * 10; }
    }
    return -1;
};
print(N);
`), ["7", "30"]);
});

test("@comptime @switch selects a prong and propagates its return", () => {
  expectOutput(runSource(`
@const $S = @comptime {
    $x = 2;
    @switch (x) {
        1 => { return 10; },
        2 => { return 20; },
        @else => { return 99; },
    }
    return -1;
};
print(S);
@const $E = @comptime {
    $x = 7;
    @switch (x) {
        1 => { return 10; },
        2 => { return 20; },
        @else => { return 99; },
    }
    return -1;
};
print(E);
`), ["20", "99"]);
});

test("@comptime @for iterates over an array", () => {
  expectOutput(runSource(`
@const $SUM = @comptime {
    $arr = [10, 20, 30, 40];
    $s = 0;
    @for (arr) |item| {
        s += item;
    }
    return s;
};
print(SUM);
`), ["100"]);
});

test("@comptime @for iterates over an array with index capture", () => {
  expectOutput(runSource(`
@const $INDEXED = @comptime {
    $arr = [10, 20, 30];
    $res = [0, 0, 0];
    @for (arr) |val, idx| {
        res[idx] = val + idx;
    }
    return res;
};
print(INDEXED[0]);
print(INDEXED[1]);
print(INDEXED[2]);
`), ["10", "21", "32"]);
});

test("@comptime @for(true) condition loop with break", () => {
  expectOutput(runSource(`
@const $VAL = @comptime {
    $i = 0;
    @for (true) {
        i += 1;
        @if (i == 5) {
            break;
        }
    }
    return i;
};
print(VAL);
`), ["5"]);
});

test("@comptime @for(condition) while loop with continue", () => {
  expectOutput(runSource(`
@const $ODDS = @comptime {
    $sum = 0;
    @for (0..10) |i| {
        @if (i % 2 == 0) {
            continue;
        }
        sum += i;
    }
    return sum;
};
print(ODDS);
`), ["25"]);
});

test("@comptime can mutate local struct fields and use compound assignment", () => {
  expectOutput(runSource(`
@struct Point { x: int; y: int; }
@const $P = @comptime {
    $p = Point { x: 10, y: 20 };
    p.x += 5;
    p.y = 99;
    return p;
};
print(P.x);
print(P.y);
`), ["15", "99"]);
});

test("@comptime can mutate local tuple fields", () => {
  expectOutput(runSource(`
@const $T = @comptime {
    $t = [10, 20];
    t.0 += 5;
    t.1 = 99;
    return t;
};
print(T.0);
print(T.1);
`), ["15", "99"]);
});

test("@comptime rejects mutating outer @const struct", () => {
  expectError(runSource(`
@struct Point { x: int; y: int; }
@const $ORIGIN = Point { x: 0, y: 0 };
@const $BAD = @comptime {
    ORIGIN.x = 10;
    return ORIGIN;
};
`), "Cannot mutate field of constant 'ORIGIN'");
});

test("@comptime rejects mutating outer @const array elements", () => {
  expectError(runSource(`
@const $ARR = [1, 2, 3];
@const $BAD = @comptime {
    ARR[0] = 99;
    return ARR;
};
`), "Cannot mutate elements of constant 'ARR'");
});

test("@comptime executes struct method", () => {
  expectOutput(runSource(`
@struct Rect {
    w: int;
    h: int;

    @func area(self): int {
        return self.w * self.h;
    }
}

@const $A = @comptime {
    $r = Rect { w: 10, h: 5 };
    return r.area();
};
print(A);
`), ["50"]);
});

test("@comptime loop iteration limit is configurable via LLTS_COMPTIME_MAX_LOOP_ITERATIONS env var", () => {
  const code = `
@const $VAL = @comptime {
    $sum = 0;
    @for (0..20) |i| {
        sum += i;
    }
    return sum;
};
print(VAL);
`;
  expectError(
    runSourceWithEnv(code, { LLTS_COMPTIME_MAX_LOOP_ITERATIONS: "10" }),
    "comptime loop exceeded maximum iteration limit of 10"
  );

  expectOutput(
    runSourceWithEnv(code, { LLTS_COMPTIME_MAX_LOOP_ITERATIONS: "30" }),
    ["190"]
  );
});

test("@comptime loop iteration limit is configurable via --comptime-max-loop-iterations flag", () => {
  const code = `
@const $VAL = @comptime {
    $sum = 0;
    @for (0..20) |i| {
        sum += i;
    }
    return sum;
};
print(VAL);
`;
  expectError(
    runSourceWithFlags(code, ["--comptime-max-loop-iterations", "10"]),
    "comptime loop exceeded maximum iteration limit of 10"
  );

  expectOutput(
    runSourceWithFlags(code, ["--comptime-max-loop-iterations", "50"]),
    ["190"]
  );
});

test("@comptime condition loop respects configurable iteration limit", () => {
  const code = `
@const $VAL = @comptime {
    $i = 0;
    @for (i < 50) {
        i += 1;
    }
    return i;
};
print(VAL);
`;
  expectError(
    runSourceWithEnv(code, { LLTS_COMPTIME_MAX_LOOP_ITERATIONS: "15" }),
    "comptime loop exceeded maximum iteration limit of 15"
  );
});

