/**
 * Pipe operator (`|>`).
 *
 * `lhs |> f(a)` must behave exactly like the call `f(lhs, a)`: the left
 * operand becomes the callee's *first* argument. It shares precedence with
 * `+` / `-` (left-associative).
 *
 * The suite is grouped by expectation:
 *   - accepted: compiles and runs with the expected output
 *   - rejected: compile-time errors (arity, callability, argument types)
 *   - warnings: still compiles, but reports a diagnostic on stderr
 *   - runtime:  accepted by the compiler, traps while executing
 *   - native:   `llts emit-zig` desugars pipes to ordinary calls (parity
 *               with the VM for the direct-call subset; method pipes are
 *               outside Phase 2 and must fail cleanly)
 */
import { test, expect } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  expectError,
  expectOutput,
  runCli,
  runFile,
  runSource,
  runSourceStrict,
} from "./helpers";

/** Compile a two-file program (entry imports ./lib.lls) without touching std. */
function runWithLib(entrySource: string, libSource: string) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_pipe_"));
  fs.writeFileSync(path.join(dir, "lib.lls"), libSource, "utf-8");
  const entry = path.join(dir, "main.lls");
  fs.writeFileSync(entry, entrySource, "utf-8");
  return runFile(entry);
}

// ---------------------------------------------------------------------------
// accepted
// ---------------------------------------------------------------------------

test("pipe forwards the left value as the first argument", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
print(7 |> dbl);
`),
    ["14"],
  );
});

test("pipe forwards the left value plus trailing arguments", () => {
  expectOutput(
    runSource(`
@func add(a: int, b: int) { return a + b; }
@func add3(a: int, b: int, c: int) { return a + b + c; }
print(10 |> add(5));
print(10 |> add3(5, 6));
`),
    ["15", "21"],
  );
});

test("pipe into an unannotated function", () => {
  expectOutput(
    runSource(`
@func add(a, b) { return a + b; }
print(10 |> add(5));
`),
    ["15"],
  );
});

test("pipe chains left to right", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
@func inc(a: int) { return a + 1; }
print(5 |> dbl |> inc |> dbl);
`),
    ["22"],
  );
});

test("pipe shares precedence with + and - (left-associative)", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
print(1 + 2 |> dbl);
print(2 * 3 |> dbl);
print(1 |> dbl + 1);
print(1 |> dbl - 1);
`),
    ["6", "12", "3", "1"],
  );
});

test("pipe accepts any left-hand expression", () => {
  expectOutput(
    runSource(`
@func add(a: int, b: int) { return a + b; }
@func dbl(a: int) { return a * 2; }
print(add(1, 2) |> dbl);
print((3 + 4) |> dbl);
`),
    ["6", "14"],
  );
});

test("pipe into a function from an imported module", () => {
  const res = runWithLib(
    `
$lib = @import("./lib.lls");
42 |> lib.show;
pub @func main() {}
`,
    `
pub @func show(v: int) { print(v); }
`,
  );
  expectOutput(res, ["42"]);
});

test("pipe into a first-class function value", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
$g = dbl;
print(3 |> g);
`),
    ["6"],
  );
});

test("pipe into a method resolves the receiver from the callee", () => {
  expectOutput(
    runSource(`
@struct Counter {
    value: i64;
    @func add(self: Counter, by: i64) { return Counter { value: self.value + by }; }
}
$c = Counter { value: 1 };
$d = 4 |> c.add;
print(d.value);
`),
    ["5"],
  );
});

test("piped expression appears inside call arguments", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
@func sum(a: int, b: int) { return a + b; }
print(sum(3 |> dbl, 4));
`),
    ["10"],
  );
});

test("piped expression works as an @if condition", () => {
  expectOutput(
    runSource(`
@func isEven(a: int) { return a % 2 == 0; }
@if (6 |> isEven) {
    print("even");
} @else {
    print("odd");
}
@if (7 |> isEven) {
    print("even");
} @else {
    print("odd");
}
`),
    ["even", "odd"],
  );
});

test("pipe works in top-level (global) code", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
$top = 21 |> dbl;
pub @func main() { print(top); }
`),
    ["42"],
  );
});

test("piped result has a concrete type for local annotations", () => {
  expectOutput(
    runSource(`
@func dbl(a: int) { return a * 2; }
$i: int = 5 |> dbl;
print(i);
`),
    ["10"],
  );
});

test("pipe as a statement forwards its value", () => {
  const res = runWithLib(
    `
$lib = @import("./lib.lls");
"ready" |> lib.shout;
pub @func main() {}
`,
    `
pub @func shout(msg: string) { print(msg); }
`,
  );
  expectOutput(res, ["ready"]);
});

test("pipe threads aggregates through a pipeline", () => {
  expectOutput(
    runSource(`
@struct Point { x: int; y: int; }
@func make(x: int) { return Point { x: x, y: x * 2 }; }
@func width(p: Point) { return p.x; }
print(3 |> make |> width);
`),
    ["3"],
  );
});

test("strict mode infers the piped call's result type", () => {
  expectOutput(
    runSourceStrict(`
@func dbl(a: int) { return a * 2; }
$x = 3 |> dbl;
print(x);
`),
    ["6"],
  );
});

test("strict mode accepts an annotated piped result", () => {
  expectOutput(
    runSourceStrict(`
@func dbl(a: int) { return a * 2; }
$x: int = 3 |> dbl;
print(x);
`),
    ["6"],
  );
});

test("strict mode types a piped @if condition as bool", () => {
  expectOutput(
    runSourceStrict(`
@func isEven(a: int) { return a % 2 == 0; }
@if (6 |> isEven) {
    print("even");
}
`),
    ["even"],
  );
});

// ---------------------------------------------------------------------------
// rejected (compile-time errors)
// ---------------------------------------------------------------------------

test("unknown piped callee is rejected", () => {
  expectError(
    runSource(`
$x = 5 |> nope;
`),
    "Unknown identifier 'nope'",
  );
});

test("too few arguments is rejected", () => {
  expectError(
    runSource(`
@func add(a: int, b: int) { return a + b; }
print(5 |> add);
`),
    "Function 'add' expected 2 arguments, got 1",
  );
});

test("too many trailing arguments are rejected", () => {
  expectError(
    runSource(`
@func add(a: int, b: int) { return a + b; }
print(5 |> add(1, 2));
`),
    "Function 'add' expected 2 arguments, got 3",
  );
});

test("piping a literal into itself is rejected", () => {
  expectError(
    runSource(`
print(3 |> 5);
`),
    "Pipe target must be a function",
  );
});

test("piping into a non-callable variable is rejected", () => {
  expectError(
    runSource(`
$g = 5;
print(3 |> g);
`),
    "Pipe target must be a function",
  );
});

test("piping a mismatched argument type is rejected", () => {
  expectError(
    runSource(`
@struct Point { x: int; y: int; }
@func dbl(a: int) { return a * 2; }
$p = Point { x: 1, y: 2 };
print(p |> dbl);
`),
    "argument 1 of 'dbl'",
  );
});

test("piping into a missing method is rejected", () => {
  expectError(
    runSource(`
@struct Counter {
    value: i64;
    @func add(self: Counter, by: i64) { return Counter { value: self.value + by }; }
}
$c = Counter { value: 1 };
c |> c.nope;
`),
    "does not exist on 'Counter'",
  );
});

// ---------------------------------------------------------------------------
// warnings (accepted, but reported)
// ---------------------------------------------------------------------------

test("unused piped result warns", () => {
  const res = runSource(`
@func dbl(a: int) { return a * 2; }
$x = 5 |> dbl;
`);
  expect(res.exitCode).toBe(0);
  expect(res.stderr).toContain("Warning: unused variable 'x'");
});

test("piped callee counts as used", () => {
  const res = runSource(`
@func dbl(a: int) { return a * 2; }
print(5 |> dbl);
`);
  expect(res.exitCode).toBe(0);
  expect(res.stderr).not.toContain("unused function");
});

test("narrowing the piped argument warns but runs", () => {
  const res = runSource(`
@func narrow(a: i32) { return a; }
$v: i64 = 5;
print(v |> narrow);
`);
  expect(res.exitCode).toBe(0);
  expect(res.stderr).toContain("implicit narrowing from 'i64' to 'i32'");
  expect(res.stdout.trim()).toBe("5");
});

// ---------------------------------------------------------------------------
// runtime failures (accepted by the compiler, traps while executing)
// ---------------------------------------------------------------------------

test("piped argument reaches a runtime bounds trap", () => {
  expectError(
    runSource(`
@func pick(xs: [3]int, i: int) { return xs[i]; }
$a: [3]int = [1, 2, 3];
print(a |> pick(7));
`),
    "Array index out of bounds",
  );
});

// ---------------------------------------------------------------------------
// native backend (llts emit-zig): pipes desugar to ordinary calls
// ---------------------------------------------------------------------------

const ROOT = path.resolve(import.meta.dir, "..");
const ZIG_BIN = process.env.LLTS_ZIG_BIN || "zig";

function emitZig(source: string): {
  sourcePath: string;
  outputPath: string;
  cleanup: () => void;
} {
  const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const sourcePath = path.join(os.tmpdir(), `llts_pipe_native_${id}.lls`);
  const outputPath = path.join(ROOT, `.tmp_pipe_native_${id}.zig`);
  fs.writeFileSync(sourcePath, source, "utf-8");
  return {
    sourcePath,
    outputPath,
    cleanup: () => {
      if (fs.existsSync(sourcePath)) fs.unlinkSync(sourcePath);
      if (fs.existsSync(outputPath)) fs.unlinkSync(outputPath);
    },
  };
}

function expectNativeParity(
  source: string,
  checkGenerated?: (code: string) => void,
) {
  const emitted = emitZig(source);
  try {
    const emit = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(emit.stderr + emit.stdout).toBe("");
    expect(emit.exitCode).toBe(0);
    if (checkGenerated)
      checkGenerated(fs.readFileSync(emitted.outputPath, "utf-8"));

    const native = spawnSync([ZIG_BIN, "run", "-lc", emitted.outputPath], {
      cwd: ROOT,
    });
    const nativeOut = native.stdout.toString();
    const nativeErr = native.stderr.toString();
    const vm = runFile(emitted.sourcePath);
    expect(native.exitCode).toBe(vm.exitCode);
    expect(nativeOut).toBe(vm.stdout);
    expect(nativeErr).toBe(vm.stderr);
  } finally {
    emitted.cleanup();
  }
}

test("native: pipes desugar to first-argument calls", () => {
  expectNativeParity(
    `
@func dbl(a: int) { return a * 2; }
@func add(a: int, b: int) { return a + b; }
pub @func main() {
	$x = 3 |> dbl;
	print(x);
	print(10 |> add(5));
}
`,
    (generated) => {
      expect(generated).toContain("lls_fn_dbl(ctx, 3)");
      expect(generated).toContain("lls_fn_add(ctx, 10, 5)");
      expect(generated).not.toContain("rt.pipe");
    },
  );
}, 60_000);

test("native: chained, nested, and precedence pipes match the VM", () => {
  expectNativeParity(
    `
@func dbl(a: int) { return a * 2; }
@func sum(a: int, b: int) { return a + b; }
@func isEven(a: int) { return a % 2 == 0; }
pub @func main() {
	print(5 |> dbl |> dbl);
	print(1 + 2 |> dbl);
	print(sum(3 |> dbl, 4));
	@if (6 |> isEven) {
		print("even");
	}
}
`,
    (generated) => {
      expect(generated).toContain("lls_fn_dbl(ctx, (try lls_fn_dbl(ctx, 5)))");
      expect(generated).toContain("lls_fn_dbl(ctx, (try rt.arith.add(1, 2)))");
      expect(generated).toContain("lls_fn_isEven(ctx, 6)");
    },
  );
}, 60_000);

test("native: method pipe fails cleanly on the native backend", () => {
  const emitted = emitZig(
    `
@struct Counter {
	value: i64;
	@func add(self: Counter, by: i64) { return Counter { value: self.value + by }; }
}
pub @func main() {
	$c = Counter { value: 1 };
	$d = 4 |> c.add;
	print(d.value);
}
`,
  );
  try {
    const emit = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(emit.exitCode).not.toBe(0);
    // Depending on how much of struct/method lowering the backend has,
    // this stops at struct types ("does not support type 'Counter'") or
    // at the pipe itself ("only supports direct function calls").
    // Either way it must be a clean Phase 2 capability error, not a crash.
    expect(emit.stderr).toContain("native backend (Phase 2)");
    expect(emit.stderr).not.toContain("panic");
  } finally {
    emitted.cleanup();
  }
});

test("native: non-callable pipe target is rejected before emission", () => {
  const emitted = emitZig(
    `
pub @func main() {
	print(3 |> 5);
}
`,
  );
  try {
    const emit = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(emit.exitCode).not.toBe(0);
    expect(emit.stderr).toContain("Pipe target must be a function");
  } finally {
    emitted.cleanup();
  }
});
