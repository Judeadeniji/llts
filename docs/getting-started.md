# Getting Started with LLTS

Welcome to LLTS! This guide will walk you through setting up the LLTS toolchain, writing and running your first program, understanding the two compiler backends, and configuring your editor.

---

## 1. Prerequisites

To build and run LLTS, you need:

- **Zig 0.15.2 or newer**  
  Verify your installed version:
  ```bash
  zig version
  ```
  If you need to install or update Zig, download it from [ziglang.org/download](https://ziglang.org/download/).

- **Git**  
  Used to clone the repository.

- **Bun** *(optional)*  
  Only required if you want to run the JavaScript-based language conformance test suite.

---

## 2. Building LLTS

Clone the repository and build the toolchain using Zig:

```bash
git clone https://github.com/your-org/llts-zig.git
cd llts-zig

# Build debug binaries
zig build
```

This compiles two binaries in `zig-out/bin/`:

| Binary | Description |
| :--- | :--- |
| `zig-out/bin/llts` | The compiler CLI, bytecode VM, and native driver |
| `zig-out/bin/llts-lsp` | The Language Server Protocol (LSP) daemon |

### Fast Everyday Builds (`release`)

For everyday use or faster compilation cycles, build with the `release` step:

```bash
zig build release
```

This rebuilds both binaries in `ReleaseSafe` mode into `zig-out/bin/`, providing faster compiler performance and runtime execution.

### Adding LLTS to your `PATH`

To run `llts` from anywhere, add `zig-out/bin` to your shell's PATH:

```bash
export PATH="$(pwd)/zig-out/bin:$PATH"
```

Verify your installation:

```bash
llts version
```

---

## 3. Your First Program: "Hello, World!"

LLTS source files use the `.lls` file extension.

Create a new file named `hello.lls`:

```lls
pub @func main() {
    print("Hello, World!");
}
```

In LLTS:
- Functions are declared with `@func`.
- `pub` marks symbols visible as the module entry point.
- `print(...)` is a built-in function that prints to standard output with a trailing newline.

### Option A: Run on the Bytecode VM

The bytecode VM offers near-instant startup for rapid iteration:

```bash
llts run hello.lls
```

Output:
```
Hello, World!
```

You can also precompile to a bytecode container (`.llb`) and execute it:

```bash
# Compile to bytecode
llts build hello.lls -o hello.llb

# Run the bytecode
llts run hello.llb
```

### Option B: Compile to a Standalone Native Executable

LLTS features a native backend that lowers your code to optimized Zig and invokes the Zig compiler to produce a standalone machine-code binary:

```bash
# Compile to a native binary
llts build hello.lls --native -o hello

# Run the binary directly
./hello
```

Alternatively, compile and run natively in a single step:

```bash
llts run hello.lls --native
```

---

## 4. Understanding the Two Backends

LLTS provides two execution pipelines that share the same front end (scanner, parser, and typechecker):

```
                   ┌──────────┐
                   │  Source  │ (.lls)
                   └────┬─────┘
                        │
                ┌───────▼───────┐
                │ Typecheck/IR  │
                └───────┬───────┘
           ┌────────────┴────────────┐
           ▼                         ▼
   ┌───────────────┐         ┌───────────────┐
   │ Bytecode Gen  │         │ Zig Emitter   │
   └───────┬───────┘         └───────┬───────┘
           ▼                         ▼
   ┌───────────────┐         ┌───────────────┐
   │ Stack VM      │         │ Zig Compiler  │
   │ (.llb)        │         │ (Native EXE)  │
   └───────────────┘         └───────────────┘
```

1. **Bytecode Compiler & Stack VM**
   - Ideal for rapid testing and development.
   - Inspect bytecode instructions with:
     ```bash
     llts dump hello.lls
     ```

2. **Native Backend (`--native`)**
   - Compiles down to optimized machine code with zero VM overhead.
   - Strictly enforces sound type safety (`--strict` is enabled automatically).
   - Supports hardware-level intrinsics such as inline assembly (`@asm`).
   - Accepts native build flags:
     ```bash
     llts build hello.lls --native -O ReleaseFast --target x86_64-linux -o hello
     ```
   - Inspect the generated Zig code with:
     ```bash
     llts emit-zig hello.lls -o hello.zig
     ```

---

## 5. Basic Syntax Overview

Here is a quick look at fundamental LLTS constructs:

### Variables & Bindings
Bindings are introduced with `$`. The sigil is only used at the declaration site:

```lls
# Mutable binding
$count = 10;
count += 1;

# Immutable binding
@const $pi = 3.14159;

# Explicit type annotation
$message: string = "Welcome";
```

### Primitive Types & Honest Widths
Numeric types have honest, explicit widths:

```lls
$small: i8 = 127;
$big: i64 = 9_000_000_000;
$byte_val: u8 = 255;
$is_active: bool = true;       # u1 / bool
$ratio: f64 = 0.5;

# Explicit conversions with @as
$widened = @as(i64, small);
```

### Control Flow
Conditionals and loops use `@`-prefixed keywords:

```lls
# Conditionals
@if (count > 0) {
    print("positive");
} @else {
    print("zero or negative");
}

# Range loops
@for (0..5) |i| {
    print(i);
}

# Switch pattern matching
$status = "ok";
$code = @switch (status) {
    "ok" => { break 200; },
    "error" => { break 500; },
    @else => { break 400; },
};
```

### Structs and Methods
Structs are frame-local aggregate types with methods:

```lls
@struct Point {
    x: f64;
    y: f64;

    @func length(self): f64 {
        return (self.x * self.x + self.y * self.y) ** 0.5;
    }
}

pub @func main() {
    $pt = Point { x: 3.0, y: 4.0 };
    print(pt.length()); # 5.0
}
```

---

## 6. Editor Setup (VS Code / Cursor)

LLTS includes tree-sitter highlighting and Language Server integration in `editors/vscode-llts/`.

### Installing the Extension Locally

```bash
cd editors/vscode-llts
bun install
bun run compile

# Symlink into your editor's extension folder:
# For VS Code:
ln -s "$(pwd)" ~/.vscode/extensions/llts.llts-0.1.0

# For Cursor:
ln -s "$(pwd)" ~/.cursor/extensions/llts.llts-0.1.0
```

After restarting your editor and building the project (`zig build`), the extension will automatically launch `zig-out/bin/llts-lsp` to provide syntax highlighting, diagnostics, hover definitions, and go-to-definition.

---

## 7. Running Tests

To verify that the entire toolchain works properly on your machine:

```bash
# Run Zig unit, compiler, runtime, and LSP tests
zig build test

# Run the Bun language conformance test suite
bun test tests/
```

---

## 8. Where to Go Next

- [**Language Reference**](./language-reference.md) — Comprehensive guide to declarations, types, operators, memory semantics, and modules.
- [**Inline Assembly Guide**](./inline-assembly.md) — Deep-dive into writing hardware-level `@asm` in native builds.
- [**Documentation Roadmap**](./todo.md) — Full language feature matrix and tracking checklist.
