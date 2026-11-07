/**
 * Zig-style labeled `@switch` continue: `continue :label value;` stores a new
 * scrutinee and re-runs dispatch. These run on the VM (`run`, no `--native`):
 * the native backend reports the feature as unsupported for now.
 */
import { test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  expectError,
  expectOutput,
  runCli,
  runFile,
  type RunResult,
} from "./helpers";

function withTempSource(source: string): string {
  const tmp = path.join(
    os.tmpdir(),
    `llts_switch_continue_${Date.now()}_${Math.random().toString(36).slice(2)}.lls`,
  );
  fs.writeFileSync(tmp, source, "utf-8");
  return tmp;
}

function runVm(source: string): RunResult {
  const tmp = withTempSource(source);
  try {
    return runCli(["run", tmp]);
  } finally {
    fs.unlinkSync(tmp);
  }
}

function runNative(source: string): RunResult {
  const tmp = withTempSource(source);
  try {
    return runFile(tmp);
  } finally {
    fs.unlinkSync(tmp);
  }
}

test("continue :label value re-runs the labeled @switch", () => {
  expectOutput(
    runVm(`
pub @func main() {
  $n: int = 1;
  $out: int = 0;
  sw: @switch (n) {
    1 => { n = 2; continue :sw n; },
    2 => { out = out + 10; continue :sw 3; },
    3 => { out = out + 100; },
    @else => { out = -1; },
  }
  print(out);
}
`),
    ["110"],
  );
});

test("continue targets the @switch from inside a nested loop", () => {
  expectOutput(
    runVm(`
pub @func main() {
  $state: int = 0;
  $out: int = 0;
  sw: @switch (state) {
    0 => {
      @for (0..3) |i| {
        continue :sw 1;
      }
      out = 999;
    },
    1 => { out = 7; },
    @else => { out = -1; },
  }
  print(out);
}
`),
    ["7"],
  );
});

test("plain continue inside a switch still targets the enclosing loop", () => {
  expectOutput(
    runVm(`
pub @func main() {
  @for (0..5) |i| {
    @switch (i) {
      2 => { continue; },
      @else => {},
    }
    print(i);
  }
}
`),
    ["0", "1", "3", "4"],
  );
});

test("continue value must be assignable to the switch scrutinee", () => {
  expectError(
    runVm(`
pub @func main() {
  $n: int = 1;
  sw: @switch (n) {
    1 => { continue :sw "two"; },
    @else => {},
  }
  print(n);
}
`),
    "continue value",
  );
});

test("switching with a value continue requires an operand", () => {
  expectError(
    runVm(`
pub @func main() {
  $n: int = 1;
  sw: @switch (n) {
    1 => { continue :sw; },
    @else => {},
  }
  print(n);
}
`),
    "requires a value",
  );
});

test("native: continue :label value re-runs the labeled @switch", () => {
  expectOutput(
    runNative(`
pub @func main() {
  $n: int = 1;
  $out: int = 0;
  sw: @switch (n) {
    1 => { n = 2; continue :sw n; },
    2 => { out = out + 10; continue :sw 3; },
    3 => { out = out + 100; },
    @else => { out = -1; },
  }
  print(out);
}
`),
    ["110"],
  );
}, 60_000);

test("native: continue targets the @switch from inside a nested loop", () => {
  expectOutput(
    runNative(`
pub @func main() {
  $state: int = 0;
  $out: int = 0;
  sw: @switch (state) {
    0 => {
      @for (0..3) |i| {
        continue :sw 1;
      }
      out = 999;
    },
    1 => { out = 7; },
    @else => { out = -1; },
  }
  print(out);
}
`),
    ["7"],
  );
}, 60_000);

test("native: plain continue inside a wrapping switch still targets the enclosing loop", () => {
  expectOutput(
    runNative(`
pub @func main() {
  @for (0..5) |i| {
    @switch (i) {
      2 => { continue; },
      @else => {},
    }
    print(i);
  }
}
`),
    ["0", "1", "3", "4"],
  );
}, 60_000);

test("native: plain break inside a wrapping switch exits the enclosing loop", () => {
  expectOutput(
    runNative(`
pub @func main() {
  @for (0..5) |i| {
    sw: @switch (i) {
      1 => { continue :sw 4; },
      3 => { break; },
      @else => {},
    }
    print(i);
  }
}
`),
    ["0", "1", "2"],
  );
}, 60_000);

test("loop labels cannot take a continue operand", () => {
  expectError(
    runVm(`
pub @func main() {
  outer: @for (0..3) |i| {
    continue :outer 1;
  }
}
`),
    "loops continue without a value",
  );
});
