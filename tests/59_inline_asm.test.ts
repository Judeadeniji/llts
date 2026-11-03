import { expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runCli } from "./helpers";

function withSource(
  source: string,
  run: (sourcePath: string, dir: string) => void,
) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "llts_inline_asm_"));
  const sourcePath = path.join(dir, "main.lls");
  fs.writeFileSync(sourcePath, source);
  try {
    run(sourcePath, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test("native lowers multiline @asm templates to volatile inline assembly", () => {
  withSource(
    `
pub @func main() {
    @asm(\`\`\`
    nop
    nop
    \`\`\`);
    print(42);
}
`,
    (sourcePath, dir) => {
      const zigPath = path.join(dir, "main.zig");
      const emit = runCli(["emit-zig", sourcePath, "-o", zigPath]);
      expect(emit.exitCode).toBe(0);
      expect(emit.stderr + emit.stdout).toBe("");
      expect(fs.readFileSync(zigPath, "utf8")).toContain(
        'asm volatile ("    nop\\n    nop");',
      );

      const native = runCli(["run", "--native", sourcePath]);
      expect(native.exitCode).toBe(0);
      expect(native.stdout).toBe("42\n");
      expect(native.stderr).toBe("");
    },
  );
}, 60_000);

test("@asm requires a literal template", () => {
  withSource(
    `
pub @func main() {
    $instruction = "nop";
    @asm(instruction);
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain(
        "@asm expects a string literal template",
      );
    },
  );
}, 60_000);

test("bytecode backend rejects native-only @asm", () => {
  withSource(
    `
pub @func main() {
    @asm("nop");
}
`,
    (sourcePath) => {
      const result = runCli(["run", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain(
        "@asm is only supported by the native backend",
      );
    },
  );
});
