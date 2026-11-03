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

## Language overview

### Declarations and control flow

```lls
@const $limit = 3;

@func classify(n: i64): string {
    @if (n < 0) { return "negative"; }
    @if (n == 0) { return "zero"; }
    return "positive";
}

pub @func main() {
    $total = 0;
    @for (0..limit) |i| {
        total += i;
    }

    $label = @switch (classify(total)) {
        "zero" => { break "none"; },
        "positive" => { break "some"; },
        @else => { break "unknown"; },
    };
    print(label);
}
```

- `@if` / `@else`, `@for` (range, condition, and iterable forms), and `@switch` expressions.
- `break`/`continue`, including labeled loops.
- `|>` pipes a value as the first argument of a call.
- Fenced template literals with `${expr}` interpolation.

### Types

| Kind | Syntax |
| --- | --- |
| Integers | `i8` … `i64`, `u8` … `u64`, `u1` / `bool` |
| Floats | `f32`, `f64` |
| Strings | `string` (a `[]byte` value) |
| Arrays / slices | `[N]T`, `[]T` |
| Tuples | `[A, B]` |
| Pointers | `*T`, `?*T` |
| Optionals / unions | `?T`, `A \| B` |
| Shapes | `{ x: i64; y: i64; }` |
| Nominal / transparent aliases | `@type UserId = i64;`, `@alias Id = i64;` |
| Structs / enums / errors | `@struct`, `@enum`, `@error` |
| Unit / bottom | `void`, `never` |

`@type` creates a distinct nominal type; `@alias` is transparent. Structs, enums, and typed error sets compose with unions and `@switch` narrowing.

### Memory

Aggregates are frame-local. Returning them is rejected unless the value is a
flat scalar struct that can be cloned safely:

```lls
@struct Node {
    value: i64;
    next: ?*Node;
}

@func head(node: *Node): i64 {
    return node.value;
}

pub @func main() {
    $a = Node { value: 1, next: null };
    $b = Node { value: 2, next: &a };
    print(head(&b));
}
```

Native allocation is not currently a core-language operation. A future
standard-library API will own allocation policy, growth, resizing, freeing,
and failure behavior; it will not require a compiler-known allocator method
name or a total capacity known in advance. The bytecode compiler temporarily
retains the legacy `@new(allocator, T)` intrinsic for VM compatibility.
`defer` and `errdefer` run cleanup on scope exit and on the error path
respectively.

### Errors

```lls
@error ParseError { Empty, Invalid }

@func parse(ok: bool): i64 | ParseError {
    @if (!ok) {
        return ParseError.Invalid;
    }
    return 42;
}

pub @func main() {
    $value = parse(false);
    @if (@isError(value)) {
        print("invalid input");
    }
}
```

Errors can also be created dynamically with `error("message")`. Unwrap typed errors with `?`, test any error value with `@isError`, and branch on typed error sets with `@switch`. Dynamic errors are message-only (`.message`); they do not carry a code or payload.

### Modules

```lls
# math.lls
pub @func square(x: i64): i64 {
    return x * x;
}

pub @const $answer = 42;
```

```lls
# main.lls
@const $math = @import("./math.lls");

print(math.square(math.answer));
pub @func main() {}
```

Relative imports are explicit. Only `pub` declarations are visible outside their module.

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

Native code may embed target-specific, side-effecting assembly with
`@asm("template")`. The template must be a string literal; the bytecode backend
rejects this native-only intrinsic. Use a fenced multiline string for
multi-instruction templates:

````lls
@asm(```
    nop
    nop
```);
````

## Project layout

| Path | Contents |
| --- | --- |
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
