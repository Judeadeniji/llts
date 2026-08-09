# LLTS

**LLTS** stands for **Low Level TypeScript** — a small language with Zig-inspired explicit memory (`Arena`, `defer`), gradual typing, and a hand-written compiler/VM.

This repository is the **Zig** implementation (the forward path). The TypeScript prototype lives in [`llts-js`](../llts-js) and remains a language reference.

> Personal learning / systems experiment — not production software.

## Features

- Custom syntax: `@func`, `$var` declarations, `@const`, `@struct`, `@for` / `@if`
- Hand-written scanner, recursive-descent parser, AST, bytecode compiler, stack VM
- Modules (`@import`), `pub` visibility, gradual typecheck + `@typeOf`
- Explicit errors (`error(...)`, `?`), arenas + `defer` (no tracing GC)
- Standard library under `std/` (`math`, `string`, `io`, `debug`, `mem`)

## Requirements

- Zig `0.15.2`+

## Build

```bash
zig build
```

Binary: `zig-out/bin/llts`

## Run

```bash
./zig-out/bin/llts -i examples/hello-world.lls
./zig-out/bin/llts -i examples/test-std.lls
./zig-out/bin/llts -i examples/functions.lls
```

## Test

```bash
# Zig unit + integration tests
zig build test

# Language suite (Bun runner → zig-out/bin/llts)
zig build && bun test tests/
# or: bun run test
```

## Example

```lls
@func add(a: i32, b: i32): i32 {
    return a + b;
}

@func main() {
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
