# LLTS

**LLTS is a small systems language with a compact type system, Zig-inspired explicit memory, and a hand-written compiler with bytecode and native backends.**

LLTS is a name, not an acronym, and it is not TypeScript — just as LLVM is not a VM. Its type notation borrows a few ideas — structural object types, unions, and optional `?T` — but the syntax, compiler, VM, and native backend are its own.

> **Status:** experimental and pre-1.0. The language, bytecode format, and tooling interfaces may change without notice. Not production software.

## Highlights

- **Gradual, checked types.** Untyped code runs; annotated code is checked. Strict mode (`--strict`) enforces sound null and union narrowing and is on by default for native compilation.
- **Honest numeric widths.** `i8`–`i64`, `u8`–`u64`, `u1`/`bool`, `f32`, `f64`, with packed struct layout and explicit `@as` conversions.
- **Explicit memory.** Frame-local aggregates, compile-time escape checks, and
  `defer`/`errdefer`. Native allocation is intentionally outside the core
  language and will be supplied by the standard library. No tracing garbage
  collector.
- **Type-level metaprogramming.** `@typeOf`, `@sizeOf`, types as compile-time values, and type functions such as `@func Opt(T: type): type { return ?T; }`.
- **Real abstractions.** First-class functions, structs with methods, enums, tagged unions, typed error sets, modules with `pub` visibility, and pipes (`|>`).
- **Two backends.** A bytecode compiler with a stack VM, and a native pipeline that emits Zig and builds a standalone binary with the Zig compiler.
- **Tooling.** `llts` CLI, `llts-lsp`, bytecode dumps, a tree-sitter grammar, and editor integrations.

## A taste of LLTS

```lls
@struct Vec2 {
    x: f64;
    y: f64;

    @func length(self) {
        return (self.x * self.x + self.y * self.y) ** 0.5;
    }
}

@func scale(v: Vec2, factor: f64): Vec2 {
    return Vec2 { x: v.x * factor, y: v.y * factor };
}

pub @func main() {
    $v = Vec2 { x: 3.0, y: 4.0 };
    $w = scale(v, 2.0);
    print(w.length());
}
```

Bindings are introduced with `$`; the sigil is only used at the declaration site. `@const` makes a binding immutable. Comments start with `#`.

## Documentation

Comprehensive guides are available in the [`docs/`](./docs) directory:

- [**Getting Started**](./docs/getting-started.md) — Prerequisites, building from source, writing your first `.lls` program, and running on the VM vs native compiler.
- [**Language Tour**](./docs/tour.md) — Fast-paced walkthrough of LLTS: bindings, honest widths, arrays/slices, control flow expressions, methods, memory model, errors, and metaprogramming.
- [**Language Reference**](./docs/language-reference.md) — Detailed guide to declarations, control flow, operators, type system, memory semantics, error handling, and modules.
- [**Inline Assembly Guide**](./docs/inline-assembly.md) — Reference for the `@asm` intrinsic in native compilation, including operand constraints, clobbers, register mapping, and verified Linux x86-64 examples.

## Build

Requirements:

- Zig **0.15.2** or newer
- Bun (only for the JavaScript test runner)

```bash
zig build
```

This produces:

- `zig-out/bin/llts` — compiler, VM, and native driver
- `zig-out/bin/llts-lsp` — language server

A Debug build is useful while working on the compiler. For everyday use:

```bash
zig build release
```

`release` rebuilds both tools in `ReleaseSafe` over `zig-out/` and is significantly faster at compile time.

## Usage

```bash
# Run a source file on the bytecode VM
zig-out/bin/llts run examples/methods.lls

# Compile to bytecode, then run it
zig-out/bin/llts build examples/methods.lls -o methods.llb
zig-out/bin/llts run methods.llb

# Compile to a native binary
zig-out/bin/llts build examples/methods.lls --native -o methods

# Inspect the generated Zig
zig-out/bin/llts emit-zig examples/methods.lls -o methods.zig

# Dump bytecode
zig-out/bin/llts dump examples/methods.lls
```

Native builds accept `--target`, `--optimize`, and `--emit bin|asm|llvm-ir|llvm-bc|h|docs|implib`. `--strict` enables the sound type system; it is implied by `--native` and `emit-zig`. Run `llts <command> --help` for the full flag set.

Native compilation also supports embedding target-specific assembly via `@asm` — see the [**Inline Assembly Guide**](./docs/inline-assembly.md) for constraints, operands, clobbers, and verified examples.

## Project layout

| Path | Contents |
| --- | --- |
| `docs/` | Language reference and guides |
| `src/scanner/` | Hand-written lexer |
| `src/parser/` | Recursive-descent parser and type syntax |
| `src/ast/` | Syntax tree |
| `src/compiler/` | Typecheck, escape analysis, layout, bytecode, and Zig emission |
| `src/bytecode/` | Instruction set and `.llb` container |
| `src/vm/` | Stack VM and builtins |
| `src/runtime/` | Support code linked into native binaries |
| `src/lsp/` | Language server |
| `examples/` | Sample programs |
| `tests/` | Zig integration tests and the Bun language suite |
| `tree-sitter-llts/` | Tree-sitter grammar |
| `editors/` | Editor integrations |
| `TODO.MD` | Feature status and roadmap |

The bytecode pipeline is scanner → parser → AST → typecheck → bytecode → VM. The native pipeline shares the front end, then emits Zig that drives the runtime and invokes the Zig compiler.

## Testing

```bash
# Zig unit, integration, LSP, and runtime tests
zig build test

# Language conformance suite (requires a built binary)
bun test tests/
```

The Bun suite is mid-migration. Suites that still import the removed `std/` tree are expected to fail until they are ported; the Zig test step is the current green baseline.

## Status and limitations

- No bundled standard library. The former `std/` tree and the self-hosted compiler have been removed from this repository; the core language and toolchain are the focus.
- Some examples and language tests still reference `std/` and are being migrated.
- Generics are currently limited to free type functions; generic struct declarations and type-parameterized methods are not yet supported.
- The native backend is under active development. VM behavior is the reference; parity coverage lives in `tests/55_emit_zig.test.ts` and `tests/57.*_native_*.test.ts`.

See [`TODO.MD`](./TODO.MD) for the detailed capability list and roadmap.
