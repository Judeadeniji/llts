/**
 * Native emitter: `llts emit-zig` must produce Zig that compiles and matches
 * the bytecode VM for the supported subset (functions, locals, scalar
 * arithmetic, strings, print, top-level code, @if, @switch, and @for).
 */
import { test, expect } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runCli, runFile } from "./helpers";

const ROOT = path.resolve(import.meta.dir, "..");
const ZIG_BIN = process.env.LLTS_ZIG_BIN || "zig";

interface Emitted {
  sourcePath: string;
  outputPath: string;
  cleanup: () => void;
}

function emitZig(source: string): Emitted {
  const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const sourcePath = path.join(os.tmpdir(), `llts_emit_zig_${id}.lls`);
  const outputPath = path.join(ROOT, `.tmp_emit_zig_${id}.zig`);
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

function runEmitted(outputPath: string) {
  const result = spawnSync([ZIG_BIN, "run", "-lc", outputPath], { cwd: ROOT });
  return {
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
    exitCode: result.exitCode ?? 1,
  };
}

/** Emit a multi-file program (entry imports `./lib.lls`) and compare with the VM. */
function expectModuleParity(
  libSource: string,
  entrySource: string,
  extraFiles: Record<string, string> = {},
  emitFlags: string[] = [],
) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_emit_mod_"));
  fs.writeFileSync(path.join(dir, "lib.lls"), libSource, "utf-8");
  for (const [name, source] of Object.entries(extraFiles)) {
    fs.writeFileSync(path.join(dir, name), source, "utf-8");
  }
  const entry = path.join(dir, "main.lls");
  fs.writeFileSync(entry, entrySource, "utf-8");
  const outputPath = path.join(
    ROOT,
    `.tmp_emit_zig_mod_${Date.now()}_${Math.random().toString(36).slice(2)}.zig`,
  );
  try {
    const emit = runCli(["emit-zig", entry, "-o", outputPath, ...emitFlags]);
    expect(emit.stderr + emit.stdout).toBe("");
    expect(emit.exitCode).toBe(0);

    const native = runEmitted(outputPath);
    const vm = runFile(entry);
    expect(native.exitCode).toBe(vm.exitCode);
    expect(native.stdout).toBe(vm.stdout);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
    if (fs.existsSync(outputPath)) fs.unlinkSync(outputPath);
  }
}

function expectParity(source: string, checkGenerated?: (code: string) => void) {
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
    if (checkGenerated) {
      checkGenerated(fs.readFileSync(emitted.outputPath, "utf-8"));
    }

    const native = runEmitted(emitted.outputPath);
    const vm = runFile(emitted.sourcePath);
    expect(native.exitCode).toBe(vm.exitCode);
    expect(native.stdout).toBe(vm.stdout);
  } finally {
    emitted.cleanup();
  }
}

test("emits functions, locals, and scalar arithmetic", () => {
  expectParity(
    `
@func add(a: int, b: int): int {
    return a + b;
}

pub @func main() {
    $a = 20;
    $b = 22;
    print(add(a, b));
    print(a * b - 10);
    print(-a);
    print(1.25 * 2.0);
}
`,
    (generated) => {
      expect(generated).not.toContain("@as(i64, lls_");
      expect(generated).not.toContain("@bitCast(lls_");
    },
  );
}, 60_000);

test("emits strings, booleans, len, and @as", () => {
  expectParity(
    `
pub @func main() {
    $s: string = @concat(0, "foo", "bar");
    print(s);
    print(len(s));
    print(s == "foobar");
    print("a" != "b");
    print(@as(u8, 42));
    print(@as(int, @as(u8, 42)));
}
`,
    (generated) => {
      expect(generated).not.toContain("@as([]const u8,");
    },
  );
}, 60_000);

test("rejects ordered string comparisons", () => {
  const emitted = emitZig(`
pub @func main() {
    print("a" < "b");
}
`);
  try {
    const result = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain(
      "comparison: expected matching numeric types",
    );
    expect(fs.existsSync(emitted.outputPath)).toBe(false);
  } finally {
    emitted.cleanup();
  }
});

test("emits top-level globals before main", () => {
  expectParity(`
@const $base = 10;
$counter = 0;
print("top");
counter = counter + 1;
print(counter);

@func get(): int {
    return base;
}

pub @func main() {
    print(get());
    print(counter);
}
`);
}, 60_000);

test("runtime traps keep the VM error message and exit code", () => {
  const emitted = emitZig(`
@func div(a: int, b: int): int {
    return a / b;
}

pub @func main() {
    print("before");
    print(div(1, 0));
}
`);
  try {
    const emit = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(emit.exitCode).toBe(0);

    const native = runEmitted(emitted.outputPath);
    const vm = runFile(emitted.sourcePath);
    expect(native.exitCode).toBe(1);
    expect(vm.exitCode).toBe(1);
    expect(native.stdout).toBe("before\n");
    expect(vm.stdout).toBe("before\n");
    expect(native.stderr).toContain("Error: Division by zero");
    expect(vm.stderr).toContain("Error: Division by zero");
  } finally {
    emitted.cleanup();
  }
}, 60_000);

test("emits @if, @else @if, and returns inside arms", () => {
  expectParity(`
@func sign(a: int): int {
    @if (a < 0) {
        return 0 - 1;
    } @else @if (a > 0) {
        return 1;
    }
    return 0;
}

pub @func main() {
    $n = 2;
    @if (n == 1) {
        print("one");
    } @else @if (n == 2) {
        print("two");
    } @else {
        print("other");
    }
    @if (false) {
        print("bad");
    }
    print(sign(0 - 5));
    print(sign(0));
    print(sign(5));
}
`);
}, 60_000);

test("emits value-producing @if with break payloads", () => {
  expectParity(`
$g = @if (true) {
    break 3;
} @else {
    break 4;
};
print(g);

pub @func main() {
    $n = 2;
    $x = @if (n == 1) {
        break 10;
    } @else @if (n == 2) {
        break 20;
    } @else {
        break 30;
    };
    print(x);

    $y = @if (n > 0) {
        @if (n == 2) {
            break 42;
        }
        break 0;
    } @else {
        break 0 - 1;
    };
    print(y);

    $word: string = @if (true) {
        break "yes";
    } @else {
        break "no";
    };
    print(word);

    $dead = @if (true) {
        $unused = 7;
        break 1;
        print(unused);
    } @else {
        break 2;
    };
    print(dead);
    print(g);
}
`);
}, 60_000);

test("emits statement and value-producing @switch", () => {
  expectParity(
    `
pub @func main() {
    $n = 2;
    @switch (n) {
        1 => { print("one"); },
        2, 3 => { print("two-three"); },
        @else => { print("other"); },
    }
    @switch (n) {
        1 => { print("only-one"); },
    }
    $x = @switch (n) {
        1 => { break 10; },
        2 => { break 20; },
        @else => { break 30; },
    };
    print(x);
    $s = @switch ("b") {
        "a" => { break 1; },
        "b" => { break 2; },
        @else => { break 3; },
    };
    print(s);
    $f = @switch (1.5) {
        1.0 => { break 4; },
        1.5 => { break 5; },
        @else => { break 6; },
    };
    print(f);
}
`,
    (generated) => {
      expect(generated).toContain("lls_sw_");
      expect(generated).toContain("rt.arith.eqStr");
    },
  );
}, 60_000);

test("emits range and condition @for loops with break/continue", () => {
  expectParity(`
pub @func main() {
    @for (0..3) |i| {
        print(i);
    }
    $n = 4;
    @for (0..n) |i| {
        @if (i == 1) {
            continue;
        }
        @if (i == 3) {
            break;
        }
        print(i);
    }
    roll: @for (0..5) |i| {
        @for (0..5) |j| {
            @if (j == 2) {
                continue :roll;
            }
            @if (i == 2) {
                break :roll;
            }
            print(i * 10 + j);
        }
    }
    unused: @for (0..2) |i| {
        print(i);
    }
    via_value: @for (0..2) |i| {
        $x = @if (i == 0) {
            @for (0..2) |j| {
                @if (j == 0) {
                    break :via_value;
                }
                break;
            }
            break 1;
        } @else {
            break 2;
        };
        print(x);
    }
    print("via-value done");
    $k = 0;
    @for (k < 3) {
        print(k);
        k = k + 1;
    }
    @for (false) {
        print("bad");
    }
}
`);
}, 60_000);

test("emits iterable @for over arrays, slices, and strings", () => {
  expectParity(`
pub @func main() {
    $arr: [3]int = [10, 20, 30];
    @for (arr) |value, index| {
        print(index);
        print(value);
    }
    $slice: []int = [9, 8];
    @for (slice) |n| {
        print(n);
    }
    $s: string = "abc";
    @for (s) |c| {
        print(c);
    }
    $count = 0;
    @for (arr) |value| {
        count = count + value;
    }
    print(count);
}
`);
}, 60_000);

test("emits structs, arrays, slices, and optionals", () => {
  expectParity(`
@struct Point {
    x: int;
    y: int;
}

@struct Box {
    point: Point;
    label: string;
}

@func maybe(flag: bool): ?Point {
    @if (flag) {
        return Point { x: 3, y: 4 };
    }
    return null;
}

pub @func main() {
    $p: Point = { x: 3, y: 4 };
    print(p.x + p.y);
    p.x = 10;
    print(p.x);

    $fixed: [3]int = [1, 2, 3];
    print(fixed[0] + fixed[2]);
    fixed[1] = 7;
    print(len(fixed));
    print(fixed[1]);

    $view: []int = fixed;
    view[0] = 50;
    print(fixed[0]);
    print(view[0]);

    $box: Box = { point: Point { x: 1, y: 2 }, label: "box" };
    box.point.x = 5;
    print(box.point.x);
    $points: [2]Point = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }];
    points[1].x = 8;
    print(points[1].x);

    $dynamic: []int = [4, 5, 6];
    dynamic[0] = 40;
    print(len(dynamic));
    print(dynamic[0]);

    $text: string = "hello";
    print(text[1..3]);
    print(len(text));

    $none: ?int = null;
    print(none);
    $some: ?int = 5;
    print(some);

    @if (maybe(true)) |point| {
        print(point.x);
        print(point.y);
    } @else {
        print("missing");
    }
    @if (maybe(false)) |point| {
        print(point.x);
    } @else {
        print("missing");
    }
}
`);
}, 60_000);

test("emits @defer on scope exit, break, continue, and return", () => {
  expectParity(`
@func valueBeforeDefer() {
    $x = 0;
    defer x = 5;
    return x;
}

@func order() {
    defer print("first");
    defer print("second");
    print("body");
}

pub @func main() {
    $x = 0;
    @for (0..3) |i| {
        defer x = x + i;
        continue;
    }
    print(x);

    @for (true) {
        defer x = x + 10;
        break;
    }
    print(x);

    $y = 0;
    @if (true) {
        defer y = y + 5;
        y = y + 1;
    }
    print(y);

    print(valueBeforeDefer());
    order();
}
`);
}, 60_000);

test("emits labeled block values, defers, and loop breaks", () => {
  expectParity(`
pub @func main() {
    $z = blk: {
        break :blk 42;
    };
    print(z);

    $sum = compute: {
        $a = 10;
        $b = 32;
        break :compute a + b;
    };
    print(sum);

    $e = blk: {
        defer print("d1");
        defer print("d2");
        break :blk "done";
    };
    print(e);

    $n = blk: {
        $i = 0;
        @for (i < 10) {
            i = i + 1;
            @if (i == 3) { break :blk i * 7; }
        }
        break :blk 0;
    };
    print(n);
}
`);
}, 60_000);

test("emits error values, sets, fields, equality, and @nameOf", () => {
  expectParity(`
@error IoError { NotFound, Denied }

@func fail(code: string): error {
    return error(code);
}

pub @func main() {
    $e: IoError = IoError.Denied;
    print(e);
    print(e.message);
    print(@isError(e));
    print(@nameOf(e));
    print(e == IoError.Denied);
    print(e != IoError.NotFound);
    print(@nameOf(IoError.NotFound));

    $open: error = fail("Nope");
    print(open);
    print(open.message);
    print(@nameOf(open));
    print(open == fail("Nope"));
    print(@isError(42));
}
`);
}, 60_000);

test("emits error unions, ?, narrowing, and @switch", () => {
  expectParity(`
@error IoError { NotFound, Denied }
@error HttpError { Timeout, Forbidden }
@type AppError = IoError | HttpError;

@func pick(n: int): int | AppError {
    @if (n == 1) { return IoError.NotFound; }
    @if (n == 2) { return HttpError.Timeout; }
    return n;
}

@func maybeFail(flag: bool): int | error {
    @if (flag) { return 7; }
    return error("bad");
}

@func openfail(): int | error {
    return error("OpenBoom");
}

pub @func main() {
    print(pick(0)?);
    $a = pick(1);
    @if (@isError(a)) {
        print(a.message);
        print(@nameOf(a));
        print(a == IoError.NotFound);
        @switch (a) {
            IoError.NotFound => { print("switch-nf"); },
            @else => { print("switch-other"); },
        }
    } @else {
        print("bad");
    }
    $b = openfail();
    @if (@isError(b)) {
        print(b.message);
        print(@nameOf(b));
    }
    $p = maybeFail(false);
    @if (@isError(p)) {
        print(p.message);
    }
    print(maybeFail(true)?);
}
`);
}, 60_000);

test("emits pointer-receiver methods and method chains", () => {
  expectParity(`
@struct Counter {
    value: int;

    @func bump(self) {
        self.value = self.value + 1;
        return self;
    }

    @func get(self) {
        return self.value;
    }
}

pub @func main() {
    $local: Counter = { value: 10 };
    $p = &local;
    print(p.bump().get());
    $other: Counter = { value: 1 };
    other.bump();
    print(other.get());
    print(local.get());
}
`);
}, 60_000);

test("emits by-value `self` methods without mutating the receiver", () => {
  expectParity(`
@struct Acc {
    v: int;

    @func bumped(self: Acc) {
        self.v = self.v + 1;
        return self.v;
    }
}

pub @func main() {
    $a: Acc = { v: 1 };
    print(a.bumped());
    print(a.v);
}
`);
}, 60_000);

test("emits module function calls, structs, and module constants", () => {
  expectModuleParity(
    `
pub @const $TWO = 2;
pub @const $NAME = "lib";

pub @struct Point { x: int; y: int; }

pub @func dbl(a: int): int { return a * 2; }

pub @func make(x: int, y: int): Point { return Point { x: x, y: y }; }
`,
    `
@const $lib = @import("./lib.lls");

pub @func main() {
    print(lib.dbl(21));
    print(lib.TWO);
    print(lib.NAME);
    $p = lib.make(1, 2);
    print(p.x);
    print(p.y);
}
`,
  );
}, 60_000);

test("emits nested module imports", () => {
  expectModuleParity(
    `
pub @const $sub = @import("./sub.lls");
pub @func dbl(a: int): int { return a * 2; }
`,
    `
@const $lib = @import("./lib.lls");

pub @func main() {
    print(lib.dbl(3));
    print(lib.sub.quad(3));
}
`,
    { "sub.lls": `pub @func quad(a: int): int { return a * 4; }` },
  );
}, 60_000);

test("devirtualizes first-class function values into direct calls", () => {
  expectModuleParity(
    `
pub @func mul(a: int, b: int): int { return a * b; }
`,
    `
@const $lib = @import("./lib.lls");

@func add(x: int, y: int): int { return x + y; }

@func getAdder(n: int) {
    _ = n;
    return add;
}

@struct Iter {
    value: int;

    @func next(self) { return add; }
}

@func get(): Iter {
    return Iter { value: 0 };
}

$pick = lib.mul;

pub @func main() {
    print(getAdder(1)(2, 3));
    print((get().next())(4, 5));
    print(pick(6, 7));
    _ = pick;
}
`,
    { "lib.lls": `pub @func mul(a: int, b: int): int { return a * b; }` },
    // Function-value declarations have no inferred type yet, so strict mode
    // rejects them at typecheck; the emitter's devirtualization is what's tested.
    ["--strict=false"],
  );
}, 60_000);

test("rejects materializing a function value at runtime", () => {
  const emitted = emitZig(`
@func add(x: int, y: int): int { return x + y; }

@func getAdder() { return add; }

pub @func main() {
    print(getAdder());
}
`);
  try {
    const emit = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(emit.exitCode).not.toBe(0);
    expect(emit.stderr).toContain("cannot materialize function value");
    expect(emit.stderr).not.toContain("panic");
  } finally {
    emitted.cleanup();
  }
});

test("emits stateful module globals", () => {
  expectModuleParity(
    `
$count = 0;

pub @func bump(): int {
    count = count + 1;
    return count;
}

pub @func peek(): int { return count; }
`,
    `
@const $lib = @import("./lib.lls");

pub @func main() {
    print(lib.bump());
    print(lib.bump());
    print(lib.peek());
}
`,
  );
}, 60_000);

test("emits errdefer and defer in LIFO order on success and error paths", () => {
  expectParity(`
$log = "";

@func note(s: string) {
    log = @concat(0, log, s);
}

@func work(fail: bool): bool | error {
    defer note("d1");
    errdefer note("e1");
    defer note("d2");
    errdefer note("e2");
    @if (fail) {
        return error("boom");
    }
    return true;
}

pub @func main() {
    print(work(false)?);
    print(log);
    $bad = work(true);
    print(@isError(bad));
    print(log);
}
`);
}, 60_000);

test("both backends reject error() with a payload argument", () => {
  const emitted = emitZig(`
pub @func main() {
    $e = error("a", "b");
}
`);
  try {
    const vm = runCli(["run", emitted.sourcePath]);
    expect(vm.exitCode).not.toBe(0);
    expect(vm.stderr).toContain("exactly 1 argument");

    const native = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(native.exitCode).not.toBe(0);
    expect(native.stderr).toContain("exactly 1 argument");
    expect(fs.existsSync(emitted.outputPath)).toBe(false);
  } finally {
    emitted.cleanup();
  }
});

test("prints @addrOf as a raw hex pointer", () => {
  const emitted = emitZig(`
@struct Point { x: int; y: int; }

pub @func main() {
    $p = Point { x: 1, y: 2 };
    print(@addrOf(p));
    $q = &p;
    print(@addrOf(q));
    print(@addrOf(p) == @addrOf(q));
}
`);
  try {
    const emit = runCli(["emit-zig", emitted.sourcePath, "-o", emitted.outputPath]);
    expect(emit.stderr + emit.stdout).toBe("");
    const native = runEmitted(emitted.outputPath);
    expect(native.exitCode).toBe(0);
    const lines = native.stdout.trimEnd().split("\n");
    expect(lines[0]).toMatch(/^0x[0-9a-f]+$/);
    expect(lines[1]).toBe(lines[0]);
    expect(lines[2]).toBe("true");
  } finally {
    emitted.cleanup();
  }
}, 60_000);

test("native rejects @new while bytecode compilation retains it", () => {
  const emitted = emitZig(`
pub @func main() {
    $buf = @new(0, [4]byte);
    print(len(buf));
}
`);
  const bytecodePath = emitted.outputPath.replace(/\.zig$/, ".llb");
  try {
    const bytecode = runCli(["build", emitted.sourcePath, "-o", bytecodePath]);
    expect(bytecode.exitCode).toBe(0);
    expect(bytecode.stderr + bytecode.stdout).toBe("");
    expect(fs.existsSync(bytecodePath)).toBe(true);

    const native = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(native.exitCode).not.toBe(0);
    expect(native.stderr).toContain(
      "@new is not part of the native core language",
    );
    expect(native.stderr).toContain("standard library");
    expect(fs.existsSync(emitted.outputPath)).toBe(false);
  } finally {
    if (fs.existsSync(bytecodePath)) fs.unlinkSync(bytecodePath);
    emitted.cleanup();
  }
});

test("prints structs as LLTS packed bytes", () => {
  expectParity(`
@struct Point { x: int; y: int; }
@struct Tiny { a: byte; b: byte; }
@struct Mixed { a: byte; b: bool; f: f64; n: int; }

pub @func main() {
    $p = Point { x: 1, y: 2 };
    print(p);
    $q = &p;
    print(q);
    $t = Tiny { a: 65, b: 66 };
    print(t);
    $m = Mixed { a: 7, b: true, f: 1.5, n: 2 };
    print(m);
}
`);
});

test("@as(string, [104, 105]) coerces integer-literal arrays to bytes", () => {
  const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const sourcePath = path.join(os.tmpdir(), `llts_as_str_${id}.lls`);
  fs.writeFileSync(
    sourcePath,
    `
pub @func main() {
    $s = @as(string, [104, 105]);
    print(s);
    $a = @as([2]u8, [104, 105]);
    print(a[0]);
    print(a[1]);
}
`,
  );
  try {
    const viaRun = runCli(["run", "--native", sourcePath]);
    expect(viaRun.exitCode).toBe(0);
    expect(viaRun.stdout).toBe("hi\n104\n105\n");
  } finally {
    fs.unlinkSync(sourcePath);
  }
}, 60_000);

test("print of an aggregate pointer is an LLTS error (no auto-deref)", () => {
  const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const sourcePath = path.join(os.tmpdir(), `llts_buf_print_${id}.lls`);
  fs.writeFileSync(
    sourcePath,
    `
pub @func main() {
    $bytes = [65, 66, 67];
    $buf = &bytes;
    print(buf);
}
`,
  );
  try {
    const res = runCli(["run", "--native", sourcePath]);
    expect(res.exitCode).not.toBe(0);
    expect(res.stderr).toContain("cannot print pointer type");
    expect(res.stderr).toContain("@as(");
    expect(res.stderr).not.toContain("pointer printing not supported");
  } finally {
    fs.unlinkSync(sourcePath);
  }
}, 60_000);

test("propagates an unhandled main error and exits nonzero", () => {
  const emitted = emitZig(`
@func fail(): int | error {
    return error("top fail");
}

pub @func main() {
    $x = fail()?;
    print(x);
}
`);
  try {
    const emit = runCli([
      "emit-zig",
      emitted.sourcePath,
      "-o",
      emitted.outputPath,
    ]);
    expect(emit.exitCode).toBe(0);
    const native = runEmitted(emitted.outputPath);
    const vm = runFile(emitted.sourcePath);
    expect(native.exitCode).toBe(1);
    expect(vm.exitCode).toBe(1);
    expect(native.stdout).toBe("");
    expect(vm.stdout).toBe("");
    expect(native.stderr).toContain("Error: top fail");
    expect(vm.stderr).toContain("Error: top fail");
  } finally {
    emitted.cleanup();
  }
}, 60_000);

test("emits pointers and address-of places", () => {
  expectParity(`
@struct Point {
    x: int;
    y: int;
}

@func bump(p: *Point) {
    p.x = p.x + 1;
}

pub @func main() {
    $p: Point = { x: 1, y: 2 };
    $q: *Point = &p;
    q.x = 5;
    print(p.x);
    bump(&p);
    print(p.x);

    $pts: [2]Point = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }];
    $rp: *Point = &pts[1];
    rp.y = 9;
    print(pts[1].y);

    $nums: [2]int = [1, 2];
    $np: *[2]int = &nums;
    print(np[1]);
    print(len(np));
    np[1] = 7;
    print(nums[1]);
}
`);
}, 60_000);
