# Tooling & CLI Reference

LLTS provides a comprehensive developer toolchain consisting of the primary command-line interface (`llts`), a language server protocol daemon (`llts-lsp`), and an official Tree-sitter parser grammar (`tree-sitter-llts`).

---

## The `llts` CLI

The `llts` binary operates as both a just-in-time runner and an optimizing compiler.

```text
Usage:
  llts [flags]
  llts <command> [flags] [arguments]

Commands:
  run        Run an LLTS source (.lls) or bytecode (.llb) file
  build      Compile source to a native binary (or bytecode with --vm)
  emit-zig   Emit generated runtime-driving Zig source
  dump       Disassemble bytecode into human-readable instructions
  version    Show compiler version
  smoke      Run built-in toolchain sanity checks
```

---

## Commands & Workflows

### 1. `llts run`

Runs a program directly. By default, it compiles ahead-of-time to a temporary native binary, executes it with the provided arguments, and cleans up automatically. Pass `--vm` to run on the bytecode virtual machine instead. Bytecode containers (`.llb`) always run on the VM.

```bash
# Compile and run as a native binary (default)
llts run src/main.lls

# Run with script arguments
llts run src/main.lls arg1 arg2 42

# Run natively with ReleaseFast optimizations
llts run -O ReleaseFast src/main.lls

# Run using the bytecode VM
llts run --vm src/main.lls

# Run an already compiled bytecode container (always uses the VM)
llts run out.llb

# Evaluate code directly without creating a file
llts -e 'print("Hello, world!")'
llts run -e 'print(1 + 2)'
```

> [!NOTE]
> Positional arguments after the file name are forwarded directly to the script when executing via `llts run`.

> [!NOTE]
> Native is the primary backend. The bytecode VM remains available behind `--vm` (and for `.llb` containers) as a compatibility and tooling path while native stdlib and parity work completes.

---

### 2. `llts build`

Compiles source code into a redistributable artifact.

#### Compiling to a Native Executable
By default, `llts build` lowers the AST and typecheck IR to native Zig source, invokes the system Zig toolchain, and links a standalone machine code binary (`out`).

```bash
# Compile to native binary (default output: ./out)
llts build src/main.lls

# Specify output executable name
llts build src/main.lls -o bin/app

# Production release build (ReleaseFast)
llts build -O ReleaseFast src/main.lls -o bin/app

# Cross-compiling for Linux ARM64
llts build --target aarch64-linux src/main.lls -o bin/app-arm64
```

#### Compiling to a Bytecode Container (`.llb`)
Pass `--vm` (or `--emit-bytecode`) to produce a self-contained bytecode container instead:

```bash
# Default bytecode output: out.llb
llts build --vm src/main.lls

# Custom output path
llts build --vm src/main.lls -o build/app.llb
```

> [!IMPORTANT]
> Strict typing is on by default for both backends. Parameter types and struct/union soundness must be explicit unless you pass `--strict false`.

#### Native Build Cache

Native builds invoke the Zig compiler, which keeps an analysis cache. `llts` points that cache at a dedicated directory instead of the project's `.zig-cache`: the project cache holds every `zig build` artifact and grows into gigabytes, and a miss there costs roughly three times a miss in a small dedicated cache. Native compilations are almost always misses (each program's text differs, so the runtime is re-analyzed), which makes that gap the dominant per-run cost.

The cache directory is resolved in this order:

| Priority | Location | When |
|---|---|---|
| 1 | `$LLTS_NATIVE_CACHE_DIR` | Always wins when set. |
| 2 | `$TMPDIR/llts-native-cache` | `TMPDIR` is set (typically `/tmp`). |
| 3 | `/tmp/llts-native-cache` | No usable `TMPDIR`, but `/tmp` exists. |
| 4 | `$XDG_CACHE_HOME/llts/native`, else `$HOME/.cache/llts/native` | No temp directory is available. |

The directory is created on demand. An empty variable is treated as unset (`TMPDIR=` does not create a relative cache path). Passing an explicit cache through `llts run --zig-args "--cache-dir=..."` (or `LLTS_ZIG_ARGS`) overrides the default and disables this resolution.

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
| `--vm` | — | — | `false` | Use the bytecode VM instead of the native backend (native is the default). |
| `--eval` | `-e` | — | `""` | Evaluate inline source code string directly. |
| `--strict` | `-s` | — | `true` | Enforce sound typing (mandatory parameter types, strict null/union safety). Pass `--strict false` to disable. |
| `--optimize` | `-O` | — | `Debug` | Native optimization mode: `Debug`, `ReleaseFast`, `ReleaseSafe`, `ReleaseSmall`. |
| `--release` | `-r` | — | `false` | Disables debug symbols; sets optimization mode to `ReleaseFast`. |
| `--target` | — | — | Host target | Target triple for cross-compilation (e.g. `x86_64-linux`, `aarch64-macos`, `x86_64-windows`). |
| `--emit` | — | — | `bin` | Native target emission kind. Options: `bin`, `asm`, `llvm-ir`, `llvm-bc`, `h`, `docs`, `implib`. |
| `--emit-bytecode` | — | — | `false` | Produce a bytecode container (implies `--vm`). |
| `--emit-zig` | — | — | `false` | Emit runtime-driving Zig source instead of compiling it. |
| `--output` | `-o` | — | `out` / `out.llb` | Destination path for compilation artifacts (`out.llb` with `--vm`). |
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
