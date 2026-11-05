import { expect, test } from "bun:test";
import { spawnSync } from "bun";
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

function exitAssembly(): { instructions: string; terminal: string } {
  switch (process.arch) {
    case "x64":
      return {
        instructions: `movq $60, %%rax
movq $42, %%rdi
syscall`,
        terminal: "syscall",
      };
    case "arm64":
      return {
        instructions: `mov x8, #93
mov x0, #42
svc #0`,
        terminal: "svc #0",
      };
    default:
      throw new Error(
        `Unsupported inline-assembly test architecture: ${process.arch}`,
      );
  }
}

function arithmeticAssembly(): {
  sum: string;
  increment: string;
} {
  switch (process.arch) {
    case "x64":
      return {
        sum: `movq %[left], %[result]
addq %[right], %[result]`,
        increment: "addq %[delta], %[value]",
      };
    case "arm64":
      return {
        sum: `mov %[result], %[left]
add %[result], %[result], %[right]`,
        increment: "add %[value], %[value], %[delta]",
      };
    default:
      throw new Error(
        `Unsupported inline-assembly test architecture: ${process.arch}`,
      );
  }
}

test("native executes a real multiline @asm system call", () => {
  const assembly = exitAssembly();
  withSource(
    `
pub @func main() {
    @asm(\`\`\`
${assembly.instructions}
    \`\`\`);
}
`,
    (sourcePath, dir) => {
      const zigPath = path.join(dir, "main.zig");
      const emit = runCli(["emit-zig", sourcePath, "-o", zigPath]);
      expect(emit.exitCode).toBe(0);
      expect(emit.stderr + emit.stdout).toBe("");
      expect(fs.readFileSync(zigPath, "utf8")).toContain(assembly.terminal);

      const binaryPath = path.join(dir, "main");
      const build = runCli([
        "build",
        sourcePath,
        "--native",
        "-o",
        binaryPath,
      ]);
      if (build.exitCode !== 0) {
        throw new Error(`Native build failed:\n${build.stderr}${build.stdout}`);
      }
      expect(build.exitCode).toBe(0);
      expect(build.stderr + build.stdout).toBe("");

      const native = spawnSync([binaryPath]);
      expect(native.exitCode).toBe(42);
      expect(native.stdout.toString()).toBe("");
      expect(native.stderr.toString()).toBe("");
    },
  );
}, 60_000);

test("extended @asm returns a typed output from input operands", () => {
  const assembly = arithmeticAssembly();
  withSource(
    `
pub @func main() {
    $left: i64 = 20;
    $right: i64 = 22;
    $sum = @asm(i64, \`\`\`
${assembly.sum}
    : [result] "=&r" (-> i64)
    : [left] "r" (\${left}),
      [right] "r" (\${right})
    :
    \`\`\`);
    print(sum);
}
`,
    (sourcePath) => {
      const native = runCli(["run", "--native", sourcePath]);
      expect(native.exitCode).toBe(0);
      expect(native.stdout).toBe("42\n");
      expect(native.stderr).toBe("");
    },
  );
}, 60_000);

test("extended @asm writes an output place and declares clobbers", () => {
  const assembly = arithmeticAssembly();
  withSource(
    `
pub @func main() {
    $value: i64 = 40;
    $delta: i64 = 2;
    @asm(void, \`\`\`
${assembly.increment}
    : [value] "+r" (\${value})
    : [delta] "r" (\${delta})
    : "memory", "cc"
    \`\`\`);
    print(value);
}
`,
    (sourcePath, dir) => {
      const zigPath = path.join(dir, "main.zig");
      const emit = runCli(["emit-zig", sourcePath, "-o", zigPath]);
      expect(emit.exitCode).toBe(0);
      expect(emit.stderr + emit.stdout).toBe("");
      expect(fs.readFileSync(zigPath, "utf8")).toContain(".memory = true");

      const native = runCli(["run", "--native", sourcePath]);
      expect(native.exitCode).toBe(0);
      expect(native.stdout).toBe("42\n");
      expect(native.stderr).toBe("");
    },
  );
}, 60_000);

test("extended @asm rejects constant output places", () => {
  const assembly = arithmeticAssembly();
  withSource(
    `
pub @func main() {
    @const $value: i64 = 40;
    $delta: i64 = 2;
    @asm(void, \`\`\`
${assembly.increment}
    : [value] "+r" (\${value})
    : [delta] "r" (\${delta})
    :
    \`\`\`);
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain(
        "@asm cannot write to constant 'value'",
      );
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

test("bytecode backend rejects extended @asm", () => {
  const assembly = arithmeticAssembly();
  withSource(
    `
pub @func main() {
    $left: i64 = 20;
    $right: i64 = 22;
    $sum = @asm(i64, \`\`\`
${assembly.sum}
    : [result] "=&r" (-> i64)
    : [left] "r" (\${left}),
      [right] "r" (\${right})
    :
    \`\`\`);
    print(sum);
}
`,
    (sourcePath) => {
      const result = runCli(["run", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain(
        "Extended @asm is only supported by the native backend",
      );
    },
  );
});

function writeSyscallAssembly(): {
  template: string;
  nr: number;
} {
  switch (process.arch) {
    case "x64":
      return {
        nr: 1, // sys_write on x86_64 Linux
        template: `syscall
    : [ret] "={rax}" (-> i64)
    : [nr] "{rax}" (\${nr}),
      [fd] "{rdi}" (\${fd}),
      [buf] "{rsi}" (\${buf_ptr}),
      [cnt] "{rdx}" (\${cnt})
    : "rcx", "r11", "memory"`,
      };
    case "arm64":
      return {
        nr: 64, // sys_write on aarch64 Linux
        template: `svc #0
    : [ret] "={x0}" (-> i64)
    : [nr] "{x8}" (\${nr}),
      [fd] "{x0}" (\${fd}),
      [buf] "{x1}" (\${buf_ptr}),
      [cnt] "{x2}" (\${cnt})
    : "memory"`,
      };
    default:
      throw new Error(
        `Unsupported inline-assembly test architecture: ${process.arch}`,
      );
  }
}

test("native executes write syscall using & on fixed-size byte buffer", () => {
  const asm = writeSyscallAssembly();
  withSource(
    `
pub @func main() {
    $buf: [3]u8 = [72, 105, 10];
    $buf_ptr = &buf;
    $nr: i64 = ${asm.nr};
    $fd: i64 = 1;
    $cnt: i64 = 3;
    $r = @asm(i64, \`\`\`
${asm.template}
    \`\`\`);
    print("bytes written:", r);
}
`,
    (sourcePath) => {
      const native = runCli(["run", "--native", sourcePath]);
      expect(native.exitCode).toBe(0);
      expect(native.stdout).toBe("Hi\nbytes written: 3\n");
      expect(native.stderr).toBe("");
    },
  );
}, 60_000);

test("@asm rejects operands larger than 8 bytes with LLTS diagnostic", () => {
  withSource(
    `
pub @func main() {
    $msg = "Hello from asm\\n";
    $nr: i64 = 1;
    $fd: i64 = 1;
    $cnt: i64 = len(msg);
    @asm(i64, \`\`\`
        syscall
        : [ret] "={rax}" (-> i64)
        : [nr] "{rax}" (\${nr}),
          [fd] "{rdi}" (\${fd}),
          [buf] "{rsi}" (\${msg}),
          [cnt] "{rdx}" (\${cnt})
        : "rcx", "r11", "memory"
    \`\`\`);
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("operand 'buf' has type 'const []u8' (16 bytes)");
      expect(result.stderr).toContain("register operands must be at most 8 bytes; pass a pointer with '&'");
      expect(result.stderr).not.toContain(".llts_native_");
    },
  );
});

test("@asm provides clear guidance when operand value is not a hole", () => {
  withSource(
    `
pub @func main() {
    @asm(void, \`\`\`
        nop
        :
        : [nr] "{rax}" (1)
        :
    \`\`\`);
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain(
        "@asm operand 'nr' must be written as '${expr}'; bind constants to a variable first, e.g. '$nr: i64 = 1;' then '(${nr})'",
      );
    },
  );
});

test("maps native Zig asm build failure to LLTS source location", () => {
  withSource(
    `
pub @func main() {
    @asm(void, \`\`\`
        nop
        :
        :
        : "invalid_clobber_for_test"
    \`\`\`);
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("inline assembly failed to compile:");
      expect(result.stderr).toContain("main.lls:3:");
      expect(result.stderr).not.toContain(".llts_native_");
    },
  );
}, 60_000);

test("contextually types array literals in typed declarations", () => {
  withSource(
    `
pub @func main() {
    $buf: [3]u8 = [72, 105, 10];
    print(buf[0]);
    print(buf[1]);
    print(buf[2]);
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).toBe(0);
      expect(result.stdout).toBe("72\n105\n10\n");
    },
  );
}, 60_000);

test("rejects overflowing elements in contextually typed array literals", () => {
  withSource(
    `
pub @func main() {
    $buf: [2]u8 = [72, 300];
}
`,
    (sourcePath) => {
      const result = runCli(["run", "--native", sourcePath]);
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("Literal 300 overflows target type 'u8'");
    },
  );
});
