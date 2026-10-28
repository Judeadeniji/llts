# LLTS Advanced Usage Guide

This document is designed for AI agents operating within the llts-zig codebase. It covers advanced language features, standard library usage, and complex idioms based on the core `.lls` examples (`pipe-ops.lls`, `test-std.lls`, and `showcase.lls`).

## Standard Library Usage

LLTS provides a modular standard library system that can be accessed via the `@import` directive.

### Importing Modules
Use `@import("path")` to include modules, binding them to constants via `@const`. Note the LLTS requirement that new variables and constants must be prefixed with `$` at the time of declaration.

```lls
// Import a whole index or specific module
@const $std = @import("std/index");
@const $fmt = @import("std/fmt");
@const $slog = @import("std/slog");
```

### Core `std` Modules
*   **`std.fmt`**: Go-compatible formatted I/O and string templating.
    *   `std.fmt.printf(format, ...args)` / `std.fmt.println(...args)`: Formatted and line-spaced printing to stdout.
    *   `std.fmt.sprintf(format, ...args)` / `std.fmt.sprint(...args)`: Formatted string construction.
    *   Supported format verbs: `%v`, `%+v`, `%#v`, `%T`, `%t`, `%d`, `%b`, `%o`, `%x`, `%X`, `%c`, `%q`, `%f`, `%s`, `%p`, etc.
*   **`std.slog` & `std.log`**: Structured and leveled logging.
    *   **Leveled Logging**: `slog.debug(msg, ...attrs)`, `slog.info(msg, ...attrs)`, `slog.warn(msg, ...attrs)`, `slog.err(msg, ...attrs)`.
    *   `slog.with(...attrs)`: Create a child logger with contextual key-value attributes.
    *   `slog.assert(condition)`: Validates state during execution. If condition is false, returns `error("AssertFailed", condition)`.
    *   Output levels can be configured via the `--log-level <LEVEL>` CLI flag or `LLTS_LOG_LEVEL` environment variable.
*   **`std.io`**: System input/output.
    *   `std.io.readLine()`: Synchronous terminal input capture.
*   **`std.math`**: Mathematical utilities.
    *   `std.math.add(a, b)`
    *   `std.math.pow(a, b)`
    *   `std.math.sqr(a)`

## Pipe Operators (`|>`)

The pipe operator (`|>`) forwards the evaluated result of the left-hand expression as the *first argument* to the function on the right. `lhs |> f(a)` is exactly the call `f(lhs, a)` — the operator is pure compile-time desugaring with no runtime support.

```lls
// Given helpers used below:
@func sqr(a: int): int { return a**2; } // Built-in exponentiation
@func dbl(a: int): int { return a * 2; }
@func add(a: int, b: int): int { return a + b; }

// 2 is piped as the argument 'a' to sqr
$a = 2 |> sqr;               // == sqr(2)

// Passing an object as the first parameter to a global function
@func printStatus(p: Player) { ... }
$hero = Player { x: 0, y: 0, health: 100, name: "Antigravity" };

// Equivalent to printStatus(hero)
hero |> printStatus;         // == printStatus(hero)

// Trailing arguments are kept: the piped value is prepended
$sum = 10 |> add(5);         // == add(10, 5)

// Chains run left to right
$doubled = 5 |> dbl |> dbl;  // == dbl(dbl(5))
```

**Semantics and rules:**

- **Precedence**: `|>` shares the additive level with `+` / `-` and is left-associative, so `1 + 2 |> dbl` groups as `(1 + 2) |> dbl` → `dbl(1 + 2)`.
- **Trailing arguments**: `lhs |> f(a, b)` becomes `f(lhs, a, b)` — the left operand is always the *first* argument.
- **Method receivers come from the callee**: `4 |> c.add` becomes `c.add(4)` — the receiver is part of the right-hand side, so the piped value fills the first *parameter* after `self`.
- **Type checking**: a pipe is checked like any other call — callee must be callable, arity and argument types are validated, and the pipe's result type is the callee's return type. So `3 |> 5` fails with `Pipe target must be a function`, and pipes type-check under `--strict` mode.
- **Unused-callee tracking**: the piped function counts as used, so `5 |> dbl` does not produce an unused-function warning.

**Backend status:**

- **Bytecode VM**: fully supported (`src/compiler/expr/call.zig` desugars pipes into ordinary calls during compilation).
- **Native backend (`llts emit-zig`)**: direct callees are supported — the emitter rewrites `lhs |> f(a)` to `f(lhs, a)` before lowering (`src/compiler/codegen/emitter/expr.zig`). Method pipes (`4 |> c.add`) are rejected with `native backend (Phase 2) only supports direct function calls` until method calls land natively.

## Structs and Object-Oriented Idioms
*See [Structs and Methods](structs_and_methods.md) for full details on this topic. For shapes vs `@struct` / `@type`, see [Shapes vs Structs](shapes_and_types.md).*

## Control Flow
*See [Control Flow](control_flow.md) and [Loops](loops.md) for full details on conditionals and iteration.*

## Error Handling and Diagnostics

The language and VM feature an advanced diagnostic subsystem (`src/errors/`) and a robust IO subsystem (`src/io/`):
*   **Error Payloads**: Error values can carry an optional payload via `error(code, payload)`. The error object exposes `.code`, `.message`, and `.payload` properties.
*   **Rich Traces**: Both compile-time and runtime errors produce precise, cross-module stack traces (e.g., `--> file.lls:line:col`), including full module import chains when resolving dependencies.
*   **Error Path Cleanup**: The `@errdefer` keyword executes deferred statements in LIFO order during error unwinds.

## Syntax Quick Reference for Agents
*   **Declarations:** `@func`, `@const`, `@struct`, `@if`, `@for`.
*   **Introspection:** `@typeOf(T_or_expr)`, `@sizeOf(T_or_expr)` — see [Errors / types](errors.md#type-introspection).
*   **Variable Binding:** Newly initialized variables must have the `$` prefix (e.g., `$my_var = 1;`), but subsequent usages must NOT use it (e.g., `my_var = 2;`).
*   **Mathematical Operators:** Contains standard operators + exponentiation (`**`).
