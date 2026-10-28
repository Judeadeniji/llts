# LLTS

**LLTS** stands for **Low Level TypeScript** — a small language with Zig-inspired explicit memory (`Arena`, `defer`), gradual typing, and a hand-written compiler/VM.

This repository is the **Zig** implementation (the forward path). The TypeScript prototype lives in [`llts-js`](../llts-js) and remains a language reference.

> Personal learning / systems experiment — not production software.

## Features

- Custom syntax: `@func`, `$var` declarations, `@const`, `@struct`, `@for` / `@if`, pipe operator `|>` (desugars to a first-argument call)
- Hand-written scanner, recursive-descent parser, AST, bytecode compiler, stack VM
- Modules (`@import`), `pub` visibility, gradual typecheck + `@typeOf` / `@sizeOf`
- Explicit errors (`error(...)`, `?`), arenas + `defer` (no tracing GC)
- Frame-local heap (bare `Foo{}` / `[…]`); escape is a compile error — use `@new(allocator, …)` with `std.mem.Arena`
- Standard library under `std/` (`math`, `string`, `io`, `debug`, `mem`)

## Requirements

- Zig `0.15.2`+

## Build

```bash
zig build
```

Binary: `zig-out/bin/llts`

`zig build` produces a Debug binary — better panics while hacking on the
compiler itself, but ~20x slower to run. For everyday use install a ReleaseSafe
build instead:

```bash
zig build release   # or: bun run build:release
```

This overwrites `zig-out/bin/llts` (and `llts-lsp` / `llts-tokenize-zig`) with
ReleaseSafe builds. A file that imports the stdlib compiles in ~0.03s instead
of ~1.3s. `zig build test` and `bun run test` both install these binaries, so
zig-out stays on the fast path after you run the tests.

## Run

```bash
./zig-out/bin/llts run examples/hello-world.lls
./zig-out/bin/llts run examples/test-std.lls
./zig-out/bin/llts run examples/functions.lls
```

## Test

```bash
# Zig unit + integration tests
zig build test

# Language suite (Bun runner → zig-out/bin/llts)
zig build release && bun test tests/
# or: bun run test            (ReleaseSafe binaries, ~7s)
# or: bun run test:debug      (Debug binaries, ~70s)
```

## Example

```lls
@func add(a: i32, b: i32): i32 {
    return a + b;
}

pub @func main() {
    $a = 1;
    $b = 2;
    $c = add(a, b);
    print(c);
}
```

## Layout

| Path | Role |
|------|------|
| `src/` | Scanner → parser → compiler → VM |
| `std/` | Standard library (`.lls`) |
| `examples/` | Sample programs |
| `tests/` | Zig `integration.zig` + Bun language suite (`*.test.ts`) |
| `TODO.MD` | Status & roadmap |

See [TODO.MD](./TODO.MD) for capabilities and remaining work.
