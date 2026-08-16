# LLTS Advanced Usage Guide

This document is designed for AI agents operating within the llts-zig codebase. It covers advanced language features, standard library usage, and complex idioms based on the core `.lls` examples (`pipe-ops.lls`, `test-std.lls`, and `showcase.lls`).

## Standard Library Usage

LLTS provides a modular standard library system that can be accessed via the `@import` directive.

### Importing Modules
Use `@import("path")` to include modules, binding them to constants via `@const`. Note the LLTS requirement that new variables and constants must be prefixed with `$` at the time of declaration.

```lls
// Import a whole index or specific module
@const $std = @import("std/index");
@const $debug = @import("std/debug");
```

### Core `std` Modules
*   **`std.debug`**: For logging, formatted printing, and testing logic.
    *   **Logging Methods**: `trace(msg)`, `debug(msg)`, `info(msg)`, `warn(msg)`, `err(msg)`, and `log(msg)` (alias for `info`). Output levels can be configured via the `--log-level <LEVEL>` CLI flag or `LLTS_LOG_LEVEL` environment variable.
    *   `std.debug.printLn("Result: {i}", val)`: Formatted string printing. Use `{s}` for strings and `{i}` for integers.
    *   `std.debug.assert(condition)`: Validates state during execution (e.g., `std.debug.assert(sum == 8);`). If the condition is false, it returns an error `error("AssertFailed", condition)`.
*   **`std.io`**: System input/output.
    *   `std.io.readLine()`: Synchronous terminal input capture.
*   **`std.math`**: Mathematical utilities.
    *   `std.math.add(a, b)`
    *   `std.math.pow(a, b)`
    *   `std.math.sqr(a)`

## Pipe Operators (`|>`)

The pipe operator (`|>`) is a functional idiom that forwards the evaluated result of the left-hand expression as the *first argument* to the function on the right. This allows readable function chaining.

```lls
@func sqr(a) {
    return a**2; // Built-in exponentiation
}

// 2 is piped as the argument 'a' to sqr
$a = 2 |> sqr; 

// Passing an object as the first parameter to a global function
@func printStatus(p: Player) { ... }
$hero = Player { x: 0, y: 0, health: 100, name: "Antigravity" };

// Equivalent to printStatus(hero)
hero |> printStatus; 
```

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
*   **Introspection:** `@typeOf(expr)`, `@sizeOf(T_or_expr)` — see [Errors / types](errors.md#type-introspection).
*   **Variable Binding:** Newly initialized variables must have the `$` prefix (e.g., `$my_var = 1;`), but subsequent usages must NOT use it (e.g., `my_var = 2;`).
*   **Mathematical Operators:** Contains standard operators + exponentiation (`**`).
