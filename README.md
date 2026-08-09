# llts (Zig)

Zig implementation of **LLTS** — scanner, parser, compiler, and stack VM.

The TypeScript prototype lives in [`llts-js`](../llts-js) and remains a language reference; this repo is the forward path.

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
```

## Test

```bash
zig build test
```

## Layout

| Path | Role |
|------|------|
| `src/` | Compiler + VM |
| `std/` | Standard library (`.lls`) |
| `examples/` | Sample programs |
| `tests/` | Zig integration tests |
