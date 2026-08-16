# Error Handling and Type Safety in LLTS

This document outlines the error handling mechanisms, type error detection, and safety checks built into the LLTS language. It is optimized for agents interacting with and generating LLTS code.

## Explicit Errors

The language provides an `error` builtin function to construct explicit error values.

### Syntax
```llts
@const $err = error("this is an error");
@const $err_with_payload = error("FileNotFound", "missing.txt");
print(err);
```
- **Behavior**: Instantiates an error object with a message string and an optional payload string.
- **Usage**: Error objects can be assigned to variables, printed, returned to the host environment, or passed to the logging subsystem.

## Typed error sets (`@error`)

Closed sets of named members (parallel to `@enum`). Prefer these over open `error("…")` when the set of failures is known.

```llts
@error IoError { NotFound, Denied }
@error HttpError { Timeout, Forbidden }

@func open(path: []byte): i64 | IoError {
  if (bad) return IoError.NotFound;
  return 7;
}

$x = open("/x")?;   # unwraps; propagates IoError

# Branding / composition (same @type / @alias rules as elsewhere)
@type NotFoundErr = IoError.NotFound;
@type MaybeBytes = IoError.NotFound | []byte;
$b = load()?;       # error-carrying through the union

# Value union of sets — @switch must cover every member of both (or @else)
@type AppError = IoError | HttpError;

# Member merge — one closed set; duplicate names across sets conflict
@type Merged = IoError & HttpError;
```

- Construct / pattern as **`IoError.NotFound`** (runtime: `OP_MAKE_ERROR`, code = member name).
- Set/member ⊑ open `error`; open `error` ≰ a specific set.
- `@switch` on a closed error-ish type is **exhaustive** (single set, `|` of sets, `&` merge, or `@else`).
- Do not mix shape `&` with error-set `&` in one intersection.

Covered by `tests/37_error_sets.test.ts`.

## Logging

LLTS provides a robust leveled logging subsystem via the standard library (`std/debug`), which outputs to `stderr`.

```llts
@const $debug = @import("std/debug");

pub @func main() {
    debug.info("Application starting");
    debug.warn("Disk space low");
    
    @const $err = error("FileNotFound", "missing.txt");
    debug.err(err);
}
```
- **Levels**: `debug.info()`, `debug.warn()`, `debug.err()`.
- **Environment Controls**:
  - `LLTS_LOG_LEVEL`: Set the minimum log level (e.g., `info`, `warn`, `error`).
  - `NO_COLOR` / `FORCE_COLOR`: Control ANSI color output.
- **Error Formatting**: Passing an `error()` object to `debug.err()` automatically formats it as a structured log without redundant `Error:` prefixes, displaying both the error code and its payload.
- **Assertions**: `debug.assert(condition)` is available and returns an `AssertFailed` error value if the condition is false.

## Diagnostics and Stack Traces

LLTS features an enhanced diagnostic reporting API:
- **Source Context**: Syntax, compile, and runtime errors print a visual source snippet with a caret (`-->`) pointing to the exact column of the fault.
- **LLTS Call Stacks**: Runtime errors display native LLTS call frames (e.g., `at func_name (file.lls)`), hiding internal host VM traces.
- **Import Tracing**: Errors originating from imported files print the full chain of `@import()` statements, tracing the module resolution path.

## Type System and Compile Errors

LLTS features a strict, static type system that performs checks at evaluation time. Violating type constraints results in a `CompileError`.

### Primitive Types
- **Numeric**: `int`, `i32`
- **Boolean**: `boolean`
- **Textual**: `string`, `[]byte`
  - String literals can be directly assigned to sized byte arrays. The length must match exactly.
  - Example: `$exact: [5]byte = "hello";`
- **Optional**: `?T` is sugar for `T | null` (either spelling is accepted; `@typeOf` prints `?T`).
  - `null` and `T` are both assignable to `?T`.
  - Field access on a `?Struct` uses `Struct`'s layout; touching `null` is a runtime error.

### Struct and Array Type Constraints
For details on type enforcement, initialization constraints, and compile errors specific to structs and arrays, see [Structs and Methods](structs_and_methods.md) and [Arrays](arrays.md). For shapes / `@type` vs `@struct`, see [Shapes vs Structs](shapes_and_types.md).


## Type Introspection

### `@typeOf`

To programmatically check types, use the `@typeOf()` builtin. Useful for assertions and debugging mismatches.

```llts
print(@typeOf(p));     # Point
print(@typeOf(n));     # i32
print(@typeOf(msg));   # []byte
print(@typeOf(grid));  # [2][2]i64
```

### `@sizeOf`

`@sizeOf(T_or_expr)` returns the packed layout size in bytes (compile-time when the argument is a type name or typed value; otherwise `OP_SIZEOF` at runtime). See `src/compiler/layout.zig`.

| Argument | Size |
|---|---|
| `u1` / `bool` / `boolean` | `1` |
| `i8` / `u8` / `byte` | `1` |
| `i16` / `u16` | `2` |
| `i32` / `u32` / `f32` | `4` |
| `i64` / `u64` / `f64` / `int` / `float` | `8` |
| `null` | `0` |
| `string` / `[]byte` (type name) | `8` (slice header) |
| struct type / typed struct value | packed field sizes + alignment |
| runtime fallback (`OP_SIZEOF`) | by value tag / dynamic layout |

```llts
print(@sizeOf(int));       # 8
print(@sizeOf(u8));        # 1
print(@sizeOf(Point));     # 24 for three i64 fields
$p = Point { x: 1, y: 2, z: 3 };
print(@sizeOf(p));         # same as @sizeOf(Point)

$x = 100;
print(@sizeOf(x));         # 8 when typed/inferred as i64
```

Expects exactly one argument. Covered by `tests/26_sizeof.test.ts` and `tests/30_widths.test.ts`.

## Key Safety Constraints
1. **Strong Typing on Assignment**: Variables initialized with explicit types (`$var: type = ...`) will reject incompatible runtime or compile-time assignments.
2. **Strict Array Bounds**: String-to-byte-array coercion requires exact size matching (e.g., `[5]byte` for `"hello"`).
3. **Struct Mutability Constraints**: Struct fields must strictly adhere to their declared types when mutated. The type system prevents arbitrary data from corrupting defined structures.
4. **Compile-Time Evaluation**: Type errors (such as attempting to assign a `[4]byte` string to an `int`) are caught as `CompileError`s before the logical flow of execution proceeds.
