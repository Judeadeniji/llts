/**
 * Native pipeline 57.4 — Compiler Authority contract enforcement.
 *
 * Asserts the three non-negotiable contract rules from Phase 4:
 * (a) Every typecheck-accepted program either lowers or fails with an explicit
 *     "native backend" unsupported-lowering diagnostic, never a semantic/type error.
 * (b) The native emitter contains no display-string type parser or AST re-evaluator.
 * (c) Generated code is deterministic when only type_of_results and resolution maps are consulted.
 */
import { test, expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { runCli, withNativeProgram } from "./helpers";

test("contract (b): emitter contains no display-string type parser or AST walks", () => {
  const emitterDir = path.resolve("src/compiler/codegen/emitter");
  const files = fs.readdirSync(emitterDir).filter((f) => f.endsWith(".zig"));

  const forbiddenPatterns = [
    "fn classify",
    "fn expandTypedefs",
    "fn isErrorDisplay",
    "fn childType",
    "fn parseArrayShape",
    "fn optionalPayloadDisplay",
    "fn isConstByteSequenceDisplay",
    "fn displayForExpr",
    "fn stmtTerminates",
    "range_mod",
    "prescan",
    "int_ranges",
  ];

  for (const file of files) {
    const content = fs.readFileSync(path.join(emitterDir, file), "utf8");
    for (const pattern of forbiddenPatterns) {
      expect(content).not.toContain(pattern);
    }
  }

  // prescan.zig and range.zig must not exist in emitter directory
  expect(fs.existsSync(path.join(emitterDir, "prescan.zig"))).toBe(false);
  expect(fs.existsSync(path.join(emitterDir, "range.zig"))).toBe(false);
});

test("contract (c): generated code is stable and deterministic across multiple emits", () => {
  const source = `
@const $FACTOR = 5;
@func compute(val: int): int {
    @if (val < 0) {
        return 0;
    }
    return val * FACTOR;
}
pub @func main() {
    $sum: int = 0;
    @for (0..10) |i| {
        sum = sum + compute(i);
    }
    print(sum);
}
`;
  withNativeProgram((sourcePath) => {
    fs.writeFileSync(sourcePath, source);
    const emit1 = runCli(["emit-zig", sourcePath]);
    const emit2 = runCli(["emit-zig", sourcePath]);

    expect(emit1.exitCode).toBe(0);
    expect(emit2.exitCode).toBe(0);
    expect(emit1.stdout).toBe(emit2.stdout);
    expect(emit1.stderr).toBe("");
    expect(emit2.stderr).toBe("");
  });
});

test("contract (a): lowering failures always produce explicit native backend diagnostics", () => {
  // 1. Fully supported programs lower with exit code 0
  const supportedPrograms = [
    "pub @func main() { print(42); }",
    `
@struct S { val: int; }
pub @func main() {
    $s = S{ val: 10 };
    print(s.val);
}
`,
    `
@func div(a: int, b: int): int {
    return a / b;
}
pub @func main() {
    print(div(10, 2));
}
`,
  ];

  for (const prog of supportedPrograms) {
    withNativeProgram((sourcePath) => {
      fs.writeFileSync(sourcePath, prog);
      const res = runCli(["emit-zig", sourcePath]);
      expect(res.exitCode).toBe(0);
      expect(res.stdout).toContain("lls_top_level");
    });
  }

  // 2. Typecheck-accepted program with unsupported lowering features rejects with explicit diagnostic
  const unsupportedProgram = `
@func variadicFunc(...args: []int) {
    return 0;
}
pub @func main() {
    print(variadicFunc(1, 2));
}
`;
  withNativeProgram((sourcePath) => {
    fs.writeFileSync(sourcePath, unsupportedProgram);
    const res = runCli(["emit-zig", sourcePath]);
    expect(res.exitCode).not.toBe(0);
    expect(res.stderr).toContain("native backend does not support variadic functions yet");
  });
});
