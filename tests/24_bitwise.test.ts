/**
 * Bitwise operators: &, |, ~ (XOR / NOT), <<, >>, and compounds.
 * `^` / `**` remain exponentiation.
 *
 * Happy-path cases run on the VM (default + --strict). Native tests cover
 * cross-backend parity for in-range values plus native-only width preservation.
 */
import { test, expect, setDefaultTimeout } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  runSource,
  runSourceStrict,
  runFile,
  runCli,
  expectOutput,
  expectError,
} from "./helpers";

setDefaultTimeout(60_000);

const ROOT = path.resolve(import.meta.dir, "..");
const ZIG_BIN = process.env.LLTS_ZIG_BIN || "zig";

function expectVmAndStrict(source: string, expected: string[]) {
  expectOutput(runSource(source), expected);
  expectOutput(runSourceStrict(source), expected);
}

function runNativeAndVm(source: string) {
  const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const sourcePath = path.join(os.tmpdir(), `llts_bitwise_${id}.lls`);
  const outputPath = path.join(ROOT, `.tmp_bitwise_${id}.zig`);
  fs.writeFileSync(sourcePath, source, "utf-8");
  try {
    const emit = runCli(["emit-zig", sourcePath, "-o", outputPath]);
    expect(emit.stderr + emit.stdout).toBe("");
    expect(emit.exitCode).toBe(0);

    const native = spawnSync([ZIG_BIN, "run", "-lc", outputPath], {
      cwd: ROOT,
    });
    const stdout = native.stdout.toString();
    const lines = stdout.split(/\r?\n/);
    while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    return {
      native: {
        stdout,
        stderr: native.stderr.toString(),
        exitCode: native.exitCode ?? 1,
        lines,
      },
      vm: runFile(sourcePath),
    };
  } finally {
    if (fs.existsSync(sourcePath)) fs.unlinkSync(sourcePath);
    if (fs.existsSync(outputPath)) fs.unlinkSync(outputPath);
  }
}

function expectNativeParity(source: string) {
  const { native, vm } = runNativeAndVm(source);
  expect(native.exitCode).toBe(vm.exitCode);
  expect(native.stdout).toBe(vm.stdout);
}

function expectNativeOutput(source: string, expected: string[]) {
  expectOutput(runNativeAndVm(source).native, expected);
}

test("bitwise AND OR XOR", () => {
  const src = `
print(0b1100 & 0b1010);
print(0b1100 | 0b1010);
print(0b1100 ~ 0b1010);
`;
  expectVmAndStrict(src, ["8", "14", "6"]);
});

test("bitwise NOT and shifts", () => {
  const src = `
print(~0);
print(1 << 4);
print(32 >> 3);
print(-8 >> 1);
`;
  expectVmAndStrict(src, ["-1", "16", "4", "-4"]);
});

test("bitwise compounds", () => {
  const src = `
$a = 0b1111;
a &= 0b1100;
print(a);
a |= 0b0011;
print(a);
a ~= 0b0101;
print(a);
$b = 1;
b <<= 3;
print(b);
b >>= 1;
print(b);
`;
  expectVmAndStrict(src, ["12", "15", "10", "8", "4"]);
});

test("^ remains power, not XOR", () => {
  const src = `
print(2 ^ 8);
print(2 ** 3);
print(7 ~ 3);
`;
  expectVmAndStrict(src, ["256", "8", "4"]);
});

test("precedence: shifts bind tighter than add; compare tighter than bitwise", () => {
  const src = `
print(1 + 2 << 2);
print(1 << 2 + 1);
print(1 | 2 == 3);
print((1 | 2) == 3);
`;
  expectVmAndStrict(src, ["12", "8", "1", "true"]);
});

test("for capture |i| still works with bitwise |", () => {
  const src = `
$sum = 0;
@for (0..4) |i| {
	sum = sum | (1 << i);
}
print(sum);
`;
  expectVmAndStrict(src, ["15"]);
});

test("type union T | error still parses", () => {
  const src = `
@func f(): int | error {
	return 1;
}
print(f());
`;
  expectVmAndStrict(src, ["1"]);
});

test("typed bitwise and shifts under strict", () => {
  const src = `
$a: i64 = 12;
$b: i64 = 10;
print(a & b);
print(a | b);
print(a ~ b);
print(a << 2);
print(a >> 1);
$c: i64 = a;
c &= b;
print(c);
$x: u8 = 12;
$y: u8 = 10;
print(x & y);
$z: i32 = 12;
print(z << 1);
$i8a: i8 = 12;
$i8b: i8 = 10;
print(i8a & i8b);
print(i8a << 2);
print(i8a >> 1);
$i16a: i16 = @as(i16, -8);
print(i16a >> 1);
$u16a: u16 = 0xFFFF;
$u16b: u16 = 0x00FF;
print(u16a & u16b);
print(u16a >> 8);
$u32a: u32 = 0x80000000;
print(u32a >> 4);
$u64a: u64 = 0xFFFFFFFF;
print(u64a & 255);
`;
  expectVmAndStrict(src, [
    "8", "14", "6", "48", "6", "8", "8", "24",
    "8", "48", "6", "-4", "255", "255", "134217728", "255",
  ]);
});

test("bitwise rejects floats", () => {
  expectError(runSource(`print(1.5 & 2);`), "integers");
  expectError(runSourceStrict(`print(1.5 & 2);`), "integers");
});

test("shift amount out of range", () => {
  expectError(runSource(`print(1 << 64);`), "Shift amount out of range");
  expectError(runSourceStrict(`print(1 << 64);`), "Shift amount out of range");
});

test("native: bitwise ops and compounds match the VM", () => {
  expectNativeParity(`
pub @func main() {
	print(0b1100 & 0b1010);
	print(0b1100 | 0b1010);
	print(0b1100 ~ 0b1010);
	print(~0);
	print(1 << 4);
	print(32 >> 3);
	print(-8 >> 1);
	$a = 0b1111;
	a &= 0b1100;
	print(a);
	a |= 0b0011;
	print(a);
	a ~= 0b0101;
	print(a);
	$b = 1;
	b <<= 3;
	print(b);
	b >>= 1;
	print(b);
	$x: u8 = 12;
	$y: u8 = 10;
	print(x & y);
	$z: i32 = 12;
	print(z << 1);
	$i8a: i8 = 12;
	$i8b: i8 = 10;
	print(i8a & i8b);
	print(i8a << 2);
	print(i8a >> 1);
	$i16a: i16 = @as(i16, -8);
	print(i16a >> 1);
	$u16a: u16 = 0xFFFF;
	$u16b: u16 = 0x00FF;
	print(u16a & u16b);
	print(u16a >> 8);
	$u32a: u32 = 0x80000000;
	print(u32a >> 4);
	$u64a: u64 = 0xFFFFFFFF;
	print(u64a & 255);
	print(1 + 2 << 2);
	print(1 | 2 == 3);
}
`);
}, 60_000);

test("native: narrow shift overflow is a checked runtime error", () => {
  expectNativeParity(`
pub @func main() {
	$x: i8 = 64;
	$y: i8 = x << 1;
	print(y);
}
`);
  expectNativeParity(`
pub @func main() {
	$x: u8 = 200;
	x <<= 1;
	print(x);
}
`);
}, 60_000);

test("native: bitwise result keeps bool width", () => {
  expectNativeOutput(
    `
pub @func main() {
	$t: bool = true;
	$f: bool = false;
	print(t & t);
	print(t | f);
	print(t ~ f);
}
`,
    ["true", "true", "true"],
  );
}, 60_000);

test("native: shift narrows at its source width before widening", () => {
  const { native } = runNativeAndVm(`
pub @func main() {
	$x: u8 = 200;
	print(@as(i16, x << 1));
}
`);
  expect(native.exitCode).not.toBe(0);
  expect(native.stderr + native.stdout).toContain("out of range");
}, 60_000);

test("native: widening before the shift avoids narrow overflow", () => {
  expectNativeOutput(
    `
pub @func main() {
	$x: u8 = 200;
	print(@as(i16, x) << 1);
}
`,
    ["400"],
  );
}, 60_000);
