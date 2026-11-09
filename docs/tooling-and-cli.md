# Tooling & CLI Reference

LLTS provides a comprehensive developer toolchain consisting of the primary command-line interface (`llts`), a language server protocol daemon (`llts-lsp`), and an official Tree-sitter parser grammar (`tree-sitter-llts`).

---

## The `llts` CLI

The `llts` binary operates as both a just-in-time runner and an optimizing compiler.

```text
Usage:
  llts <command> [flags] [arguments]

Commands:
  run        Run an LLTS source (.lls) or bytecode (.llb) file
  build      Compile source to bytecode container or native binary
  emit-zig   Emit generated runtime-driving Zig source
  dump       Disassemble bytecode into human-readable instructions
  version    Show compiler version
  smoke      Run built-in toolchain sanity checks
```

---

## Commands & Workflows

### 1. `llts run`

Runs a program directly. By default, it compiles and runs via the bytecode virtual machine. With `--native`, it compiles ahead-of-time to a temporary native binary, executes it with the provided arguments, and cleans up automatically.

```bash
# Run using the bytecode VM
llts run src/main.lls

# Run with script arguments
llts run src/main.lls arg1 arg2 42

# Run an already compiled bytecode container
llts run out.llb

# Compile and run as a native binary
llts run --native src/main.lls

# Run natively with ReleaseFast optimizations
llts run --native -O ReleaseFast src/main.lls
```

> [!NOTE]
> Positional arguments after the file name are forwarded directly to the script when executing via `llts run`.

---

### 2. `llts build`

Compiles source code into a redistributable artifact.

#### Compiling to Bytecode Container (`.llb`)
By default, `llts build` produces a self-contained bytecode container (`out.llb`):

```bash
# Default output: out.llb
llts build src/main.lls

# Custom output path
llts build src/main.lls -o build/app.llb

# Strict typechecking during bytecode compilation
llts build --strict src/main.lls -o build/app.llb
```

#### Compiling to Native Executable (`--native`)
When `--native` is supplied, LLTS lowers the AST and typecheck IR to native Zig source, invokes the system Zig toolchain, and links a standalone machine code binary.

```bash
# Compile to native binary (default output: ./out)
llts build --native src/main.lls

# Specify output executable name
llts build --native src/main.lls -o bin/app

# Production release build (ReleaseFast)
llts build --native -O ReleaseFast src/main.lls -o bin/app

# Cross-compiling for Linux ARM64
llts build --native --target aarch64-linux src/main.lls -o bin/app-arm64
```

> [!IMPORTANT]
> The native backend enforces `--strict` typing mode by default. Parameter types and struct/union soundness must be explicit.

---

### 3. `llts emit-zig`

Inspects the intermediate Zig source code emitted by the native lowering pipeline. This is useful for debugging code generation, inspecting struct layouts, or auditing inline assembly lowering:

```bash
# Emit generated Zig code to stdout
llts emit-zig src/main.lls

# Save emitted Zig code to a file
llts emit-zig src/main.lls -o generated.zig
```

---

### 4. `llts dump`

Disassembles bytecode into human-readable VM instructions, constant tables, source references, and function layout:

```bash
# Dump bytecode disassembly to stdout
llts dump src/main.lls

# Save disassembly to a file
llts dump src/main.lls -o bytecode.asm
```

Example dump output:
```text
=== bytecode dump ===
file: examples/paren_test.lls
code: 50 bytes
constants: 3
strings: 1
functions: 1
sources: 1

--- functions ---
main: addr=0003 arity=0 variadic=false source_index=0

--- constants ---
0000: 1
0001: 2
0002: 3

--- code ---
0000: OP_JUMP 5 -> 0008
0003: OP_SOURCE 0 (examples/paren_test.lls)
0006: OP_VOID
0007: OP_RETURN
0008: OP_LINE line=1 col=1
0018: OP_CONSTANT 0 (1)
0026: OP_CONSTANT 1 (2)
0029: OP_ADD_TYPED 3
0036: OP_CONSTANT 2 (3)
0039: OP_MUL_TYPED 3
0041: OP_SET_GLOBAL 0 (g)
0044: OP_POP
0045: OP_CALL_STATIC addr=0003 argc=0
0049: OP_RETURN
```

---

## Comprehensive Flag Reference

| Flag | Short | Environment Variable | Default | Description |
|---|---|---|---|---|
| `--native` | `-n` | — | `false` | Enable the native backend (compiles machine code via Zig; implies `--strict`). |
| `--strict` | `-s` | — | `false` (VM)<br>`true` (Native) | Enforce sound typing (mandatory parameter types, strict null/union safety). |
| `--optimize` | `-O` | — | `Debug` | Native optimization mode: `Debug`, `ReleaseFast`, `ReleaseSafe`, `ReleaseSmall`. |
| `--release` | `-r` | — | `false` | Disables debug symbols; sets optimization mode to `ReleaseFast`. |
| `--target` | — | — | Host target | Target triple for cross-compilation (e.g. `x86_64-linux`, `aarch64-macos`, `x86_64-windows`). |
| `--emit` | — | — | `bin` | Target emission kind (implies `--native`). Options: `bin`, `asm`, `llvm-ir`, `llvm-bc`, `h`, `docs`, `implib`. |
| `--output` | `-o` | — | `out.llb` / `out` | Destination path for compilation artifacts. |
| `--zig-bin` | — | `LLTS_ZIG_BIN` | `zig` | Custom path or binary name for the host Zig compiler executable. |
| `--zig-args` | — | `LLTS_ZIG_ARGS` | `""` | Extra flags passed directly to `zig build-exe` (e.g. `"-fstrip -flto"`). |
| `--runtime-path` | — | — | `src/runtime/root.zig` | Path to the native runtime support library. |
| `--max-memory` | `-m` | `LLTS_MAX_MEMORY` | `1048576` | Virtual machine stack/heap slot allocation limit (in words). |
| `--comptime-max-loop-iterations` | — | `LLTS_COMPTIME_MAX_LOOP_ITERATIONS` | `100000` | Safety limit for loops evaluated at compile time. |
| `--log-level` | — | — | `warn` | Toolchain verbosity (`trace`, `debug`, `info`, `warn`, `error`). |
| `--version` | `-V` | — | — | Print compiler version and exit. |

### `--emit` Artifact Kinds

The `--emit` flag exposes the full code-generation power of the native backend:
- `bin`: Self-contained native binary executable (default).
- `asm`: Clean target assembly source (`.s`).
- `llvm-ir`: Human-readable LLVM Intermediate Representation (`.ll`).
- `llvm-bc`: Binary LLVM bitcode (`.bc`).
- `h`: Generated C header bindings for exported functions and structs (`.h`).
- `docs`: Embedded documentation generation.
- `implib`: Windows PE dynamic import library (`.lib`).

---

## Language Server (`llts-lsp`)

The LLTS distribution includes an industrial-strength Language Server Protocol implementation (`llts-lsp`) designed for high responsiveness and zero configuration.

### Features
- **Diagnostics (`textDocument/publishDiagnostics`):** Instant syntax error, lexical scanner, and typecheck diagnostics with accurate token span underlines. Diagnostics are automatically throttled to prevent client flooding.
- **Hover (`textDocument/hover`):** Inspect variable types, struct layouts, enum variants, and function signatures. Documentation is formatted in LLTS-fenced Markdown blocks.
- **Go to Definition (`textDocument/definition`):** Jump to definitions of variables, parameters, functions, structs, fields, and imported module symbols.
- **Document Synchronization:** Incremental text document updates (`textDocument/didChange`).

### Editor Integration

#### Neovim (`nvim-lspconfig`)
Add to your `init.lua`:

```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.llts then
  configs.llts = {
    default_config = {
      cmd = { 'llts-lsp' },
      filetypes = { 'llts' },
      root_dir = lspconfig.util.root_pattern('.git', 'main.lls'),
      settings = {},
    },
  }
end

lspconfig.llts.setup{}
```

#### Helix (`languages.toml`)
Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "llts"
scope = "source.llts"
injection-regex = "llts"
file-types = ["lls"]
roots = ["main.lls", ".git"]
language-servers = [ "llts-lsp" ]

[language-server.llts-lsp]
command = "llts-lsp"
```

#### VS Code / Cursor
Install the official extension located in `editors/vscode-llts`. It launches `llts-lsp` automatically over stdio and wires language configuration, bracket matching, and semantic tokens.

---

## Tree-sitter Grammar (`tree-sitter-llts`)

The repository includes a complete Tree-sitter grammar in `tree-sitter-llts/` for precise syntax highlighting and structural code queries.

### Building & Testing the Grammar

```bash
cd tree-sitter-llts
bun install

# Regenerate parser from grammar.js
bun run generate

# Run corpus test suite
bun run test

# Parse a source file into a concrete syntax tree
bun run parse -- ../examples/showcase.lls

# Build WebAssembly binary for editor plugins
bunx tree-sitter build --wasm
```

### Highlights Query

The highlighting queries are located in `tree-sitter-llts/queries/highlights.scm`. They map LLTS tokens (the `$` declaration sigil, `@`-prefixed intrinsics and keywords, types, string templates, labels) to standard syntax capture groups:
- `@keyword` for control flow and storage keywords.
- `@function` for `@func` declarations and calls.
- `@type` for primitive types and user-defined structs.
- `@variable` for `$ident` bindings.
- `@constant` for `@const` definitions.
- `@string.regex` and `@string.special` for multi-line backtick templates.
