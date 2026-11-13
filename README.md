# LLTS

**LLTS is a strictly-typed systems programming language with a compact type system, explicit memory management, and a native compiler generating standalone machine binaries.**

LLTS is a name, not an acronym, and it is not TypeScript — just as LLVM is not a VM. Its type notation borrows a few ideas — structural object types, unions, and optional `?T` — but the syntax, compiler, native backend, and memory model are its own.

> **Status:** experimental and pre-1.0. The language, toolchain, and interfaces may change without notice. Not production software.

## Highlights

- **Strict, Sound Types.** All code requires explicit parameter and field type annotations. Strict mode enforces sound null and union narrowing.
- **Honest numeric widths.** `i8`–`i64`, `u8`–`u64`, `u1`/`bool`, `f32`, `f64`, with packed struct layout and explicit `@as` conversions.
- **Explicit memory.** Frame-local aggregates, compile-time escape analysis, and `defer`/`errdefer`. Memory safety is enforced by strict **Scoped Downward Borrowing & Lexical Exclusivity**. No tracing garbage collector.
- **Type-level metaprogramming.** `@typeOf`, `@sizeOf`, types as compile-time values, and type functions such as `@func Opt(T: type): type { return ?T; }`.
- **Real abstractions.** First-class functions and closures, structs with methods, enums, tagged unions, typed error sets, modules with `pub` visibility, and pipes (`|>`).
- **Native compilation.** A native pipeline that lowers to Zig and builds a standalone binary with the Zig compiler.
- **Tooling.** `llts` CLI, `llts-lsp`, a tree-sitter grammar, and editor integrations.

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

Comprehensive guides and specifications are available in the [`docs/`](./docs) directory:

- [**Getting Started**](./docs/getting-started.md) — Prerequisites, building from source, writing your first `.lls` program, and running on the VM vs native compiler.
- [**Language Tour**](./docs/tour.md) — Fast-paced walkthrough of LLTS: bindings, honest widths, arrays/slices, control flow expressions, methods, memory model, errors, and metaprogramming.
- [**Syntax & Grammar Reference**](./docs/syntax-and-grammar.md) — Formal specification of source encoding, tokens, comments, the `$` sigil, keywords, literal formats, operator precedence (14 levels), and EBNF grammar.
- [**Variables, Bindings & Scoping**](./docs/variables-and-bindings.md) — The `$` declaration sigil, mutable variables, immutable `@const` bindings, deep struct immutability, lexical scope frames, and labeled block expressions.
- [**Operators & Expressions**](./docs/operators-and-expressions.md) — Checked arithmetic traps, wrapping operators (`+%`, `-%`, `*%`), power, bitwise shifts & bounds (`0..63`), boolean short-circuiting, pipes (`|>`), and the complete 14-level precedence table.
- [**Strings & Multiline Templates**](./docs/strings-and-templates.md) — The `string` immutable byte slice type, character escapes, multiline fenced templates (`` ```...``` ``), interpolation (`${expr}`), `len()`, and `@concat`.
- [**Strings, Arrays, Slices & Tuples**](./docs/sequences.md) — Comprehensive guide to linear data: sized arrays (`[N]T`), fat-pointer slices (`[]T`), immutable strings, heterogeneous tuples (`[A, B]`), bounds safety, and escape rules.
- [**Type System Guide**](./docs/types/README.md) — Primitive widths (`i8`–`i64`, `u1`–`u64`, floats), compound data (`[N]T`, `[]T`, `[A, B]`, `*T`), algebraic types (`?T`, `A | B`, narrowing), and user types (`@struct`, `@enum`, `@error`).
- [**Type Soundness, Flow Analysis & Discriminated Unions**](./docs/type-soundness-and-flow.md) — Strict mode invariants, truthiness coercion prohibition, flow-sensitive narrowing, branch joins, and discriminated unions with kind matching.
- [**Control Flow**](./docs/control-flow.md) — Value-producing `@if`, pattern matching `@switch`, labeled continue, `@for` loops, and labeled blocks.
- [**Functions & Methods**](./docs/functions.md) — Function declarations (`@func`), entry point (`pub @func main`), variadics (`...args`), struct methods (`self` vs `self: *T`), first-class functions, and pipes (`|>`).
- [**Functional Programming & The Pipe Operator**](./docs/functional-and-pipes.md) — First-class function types (`@func(...)`), higher-order functions, closures and captures, the pipe operator (`|>`), chaining semantics, precedence, and zero-cost backend lowering.
- [**Error Handling**](./docs/error-handling.md) — Closed error sets (`@error`), dynamic errors, error unions (`T ! E`), try propagation (`?`), unwrap (`.?`), and cleanup with `errdefer`.
- [**Memory Model & Safety**](./docs/memory-and-safety.md) — Frame-local region stack allocation, compile-time escape analysis, auto-cloning scalar structs, and LIFO cleanups (`defer`/`errdefer`).
- [**Pointers & Memory Mechanics**](./docs/pointers-and-memory.md) — Aggregate-only capability pointers (`*T`, `?*T`), automatic dereferencing (`ptr.field`), address-of restrictions, aliasing, and escape analysis.
- [**Metaprogramming & Compile-Time**](./docs/metaprogramming.md) — Type introspection (`@typeOf`, `@sizeOf`, `@nameOf`), explicit casting (`@as`), generic type functions, monomorphization, and `@comptime`.
- [**Compiler Intrinsics**](./docs/intrinsics.md) — Full specification for all builtins: `@import`, `@asm`, `@as`, `@typeOf`, `@sizeOf`, `@nameOf`, `@isError`, `@addrOf`, `@concat`, `@extern`, and `@new`.
- [**Modules & Organization**](./docs/modules.md) — Multi-file projects, relative module resolution via `@import`, the `pub` visibility modifier, imported types/methods, circular dependency detection, and diagnostic import stacks.
- [**Tooling & CLI Reference**](./docs/tooling-and-cli.md) — Complete manual for the `llts` command-line tool (`run`, `build`, `emit-zig`, `dump`), compiler flags (`--native`, `--strict`, `-O`, `--target`, `--emit`), the `llts-lsp` language server, and the `tree-sitter-llts` grammar.
- [**Inline Assembly Guide**](./docs/inline-assembly.md) — Reference for the `@asm` intrinsic in native compilation, including operand constraints, clobbers, register mapping, and verified Linux x86-64 examples.
- [**Language Reference**](./docs/language-reference.md) — Core language guide covering declarations, control flow, operators, type system, memory semantics, error handling, and modules.

## Build

Requirements:

- Zig **0.15.2** or newer

```bash
zig build
```

This produces:

- `zig-out/bin/llts` — compiler and native driver
- `zig-out/bin/llts-lsp` — language server

A Debug build is useful while working on the compiler. For everyday use:

```bash
zig build release
```

`release` rebuilds both tools in `ReleaseSafe` over `zig-out/` and is significantly faster at compile time.

## Usage

```bash
# Compile and run a source file natively
llts run examples/methods.lls

# Compile to a native binary
llts build examples/methods.lls -o methods

# Inspect the generated Zig
llts emit-zig examples/methods.lls -o methods.zig
```

Native builds enforce sound typing by default. Run `llts <command> --help` for the full flag set.

### Legacy: Bytecode VM
The bytecode VM is deprecated. To run via the legacy VM:

```bash
llts run --vm examples/methods.lls
```

## Project layout

| Path | Contents |
| --- | --- |
| `docs/` | Language reference and guides |
| `src/scanner/` | Hand-written lexer |
| `src/parser/` | Recursive-descent parser and type syntax |
| `src/ast/` | Syntax tree |
| `src/compiler/` | Typecheck, escape analysis, layout, and Zig emission |
| `src/runtime/` | Support code linked into native binaries |
| `src/lsp/` | Language server |
| `examples/` | Sample programs |
| `tests/` | Zig integration tests |
| `tree-sitter-llts/` | Tree-sitter grammar |
| `editors/` | Editor integrations |
| `TODO.MD` | Feature status and roadmap |

The native pipeline shares the front end, then emits Zig that drives the runtime and invokes the Zig compiler.

## Testing

```bash
# Zig unit, integration, LSP, and runtime tests
zig build test
```

## Status and limitations

- No bundled standard library.
- Generics are currently limited to free type functions; generic struct declarations and type-parameterized methods are not yet supported.
- The bytecode VM is deprecated.

See [`TODO.MD`](./TODO.MD) for the detailed capability list and roadmap.
