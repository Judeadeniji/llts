# LLTS-Zig Architecture Overview

LLTS (Low Level TypeScript) is a small, gradually typed language featuring Zig-inspired explicit memory management (`Arena`, `defer`), and a custom, hand-written compiler and VM. This document outlines the general architecture, design goals, build pipeline, dependencies, and testing strategies for the Zig implementation.

## 1. Overall Architecture Goals

The architecture of LLTS is built upon a few key pillars, emphasizing explicit control, performance, and simplicity:

- **Custom Pipeline**: The toolchain consists of a hand-written scanner (lexer), a recursive-descent parser, an Abstract Syntax Tree (AST), a bytecode compiler, and a Stack Virtual Machine (VM).
- **Explicit Memory Management**: LLTS eschews tracing Garbage Collection (GC) in favor of explicit ownership. It introduces a frame-local heap (where bare initializations like `Foo{}` or `[...]` are bump-allocated and automatically rewound when the frame returns). Returning or escaping frame-local data results in a compile error. Persistent allocations are done via the `@new` intrinsic using `std.mem.Arena` combined with the `defer` keyword for cleanup.
- **Gradual Typing & Static Analysis**: The compiler includes a gradual typecheck pass before bytecode emission. It supports annotations (e.g., `$name: T`, `[]T`) and tracks types internally, validating returns, structural fields, and array bounds. Debug type assertions are injected, which can be stripped in release builds.
- **Explicit Error Handling**: Following Zig's philosophy, errors are explicit (using `error(...)` and `?`). 
- **Modularity**: The language features an `@import` system with `pub` visibility to properly namespace modules and user code. A standard library (`std/`) is provided for common operations (math, string, io, memory, and debugging), built on top of native VM bindings (`__*`).

## 2. Dependencies

LLTS relies on a minimalistic dependency tree:

- **Zig 0.15.2+**: The core language used to write the scanner, parser, compiler, and VM. The project heavily utilizes Zig's build system (`build.zig`) and standard library.
- **Bun**: Used strictly for the testing environment. It acts as the runner for the language conformance test suite written in TypeScript.

## 3. Build Steps

The build system is orchestrated by standard Zig tooling (`build.zig`), defining the root module, the main executable, and test suites.

To build the project:
```bash
zig build
```
This produces the main executable at `zig-out/bin/llts`.

To run an LLTS program:
```bash
./zig-out/bin/llts -i examples/hello-world.lls
```

The `build.zig` defines a `run` step, allowing executing the program via:
```bash
zig build run -- -i <path_to_lls_file>
```

## 4. Testing Strategies

Testing in LLTS is split into two primary layers to ensure both internal VM correctness and external language conformance:

### 4.1 Internal Zig Tests
Unit tests and integration tests for the internals (Scanner, Parser, Compiler, and VM) are written in Zig and run via its native test runner. The internal test runner tests components in isolation and end-to-end Zig integrations.
```bash
zig build test
```
This command runs tests across modules, specifically targeting tests defined within `src/` and integration tests located in `tests/integration.zig`.

### 4.2 Language Conformance Suite
A comprehensive test suite of the language surface is maintained in TypeScript (`tests/*.test.ts`). This external suite invokes the compiled `zig-out/bin/llts` binary using Bun to test end-to-end language execution, correct standard error reporting, and output verification.
```bash
# Ensure the binary is built, then run the Bun test suite
zig build && bun test tests/
```

### 4.3 Diagnostics and Safety
- **Stack Traces**: The VM maintains rigorous runtime tracking to emit full stack traces and source-context diagnostics directly to `stderr` upon fatal errors.
- **Type Checking Asserts**: During normal execution, type asserts are validated. Compiling with `--release` will strip these assertions for performance benchmarking.
- **Safety**: Standard safety guarantees (such as array bounds checking and `@const` immutability) are baked into both the typechecker (at compile-time) and the VM (at runtime).
