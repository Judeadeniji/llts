# LLTS Agent-Focused Basics Documentation

This document serves as an agent-focused reference for understanding the core syntax, variable semantics, and basic types of the LLTS scripting language used in the `llts-zig` project.

## 1. Syntax & Core Semantics

LLTS features a C-like/Rust-like syntax designed for simplicity and explicit scoping.

### 1.1 Comments
- Use `#` for single-line comments.
- Block comments are not explicitly highlighted in the core examples; default to multiple single-line comments.

### 1.2 Statements and Expressions
- Statements are terminated by a semicolon `;`.
- Standard operator precedence and grouping using `()` apply.
- Chained assignments are supported: `$l = a = b = c + 1;`.
- Extensive chaining semantics are supported (e.g., method chaining, function call chaining, property chaining).

## 2. Variables & Constants

### 2.1 Variable Declaration and Usage
- **Declaration:** Variables MUST be prefixed with `$` at the time of declaration.
- **Usage:** Once declared, variables MUST be referenced without the `$` prefix.
- **Example:**
```llts
$a = 1;       # Declaration uses $
$b = 2;       # Declaration uses $
$c = a + b;   # Usage of a and b drops the $
```

### 2.2 Constants
- **Declaration:** Constants are declared with the `@const` directive, followed by the `$var_name`.
- **Imports:** Typically used for library modules.
- **Example:**
```llts
@const $std = @import("std/index");
@const $msg = "Hello, LLTS!";
```

## 3. Basic Types & Memory Management

### 3.1 Types
- Integers: `i32`, `int`
- Strings: Supported as literals (e.g., `"Hello, LLTS!"`)

### 3.2 Structs
For detailed information on declaring and instantiating structs, see [Structs and Methods](structs_and_methods.md).

### 3.3 Heap Allocation
- Values that need to escape functions are allocated to an explicit heap/arena.
- The allocator is library-side, and `@new` is the compiler intrinsic used to allocate onto it.
- **Example:**
```llts
@const $mem = @import("std/mem");
$heap = mem.create(0);
# Allocate a Builder instance onto the heap
$instance = @new(heap, Builder { value: 10 });
```

## 4. Functions & Methods

### 4.1 Functions
- Declared with the `@func` directive.
- Can optionally specify type signatures for arguments and return types.
- Functions are first-class citizens and can be returned from other functions.
- **Example:**
```llts
@func add(x: i32, y: i32): i32 {
    return x + y;
}
```

### 4.2 Methods
For detailed information on struct methods, see [Structs and Methods](structs_and_methods.md).

## 5. Built-in Directives & Intrinsics
- `@import("path")`: Imports a module. Module resolution handles relative paths (`.`, `..`) and provides full stack traces on import failures.
- `@const`: Declares a constant.
- `@func`: Declares a function.
- `@struct`: Declares a struct.
- `@new(heap, instance)`: Allocates an instance on the given heap.
- `error(code, payload)`: Creates an error value with an optional payload.

## 6. Error Handling, Diagnostics, and Logging

### 6.1 Error Values
Errors are first-class values created via `error(code, payload)`. They carry a `.code` string and an optional `.payload`.
```llts
$err = error("FileNotFound", "missing.txt");
std.debug.printLn("Error: {s}", err.code);
```

### 6.2 Error-Path Cleanup (errdefer)
The `errdefer` statement runs cleanup code only if the current scope exits via an error return or an unwind. It is skipped on normal exits, `break`, or `continue`.
```llts
errdefer std.debug.info("An error occurred!");
```

### 6.3 Logging
The `std/debug` module provides leveled logging backed by a robust IO subsystem. Log output is written to stderr, optionally colored, and respects the `LLTS_LOG_LEVEL` environment variable (`trace`, `debug`, `info`, `warn`, `error`).
```llts
@const $debug = @import("std/debug");
debug.info("System initialized");
debug.err(error("FailCode", "Details")); # Auto-formats error objects
```

### 6.4 Assertions
The `std.debug.assert(condition)` function ensures invariants. It returns `null` on success and `error("AssertFailed", condition)` on failure.

## 7. Example: Hello World Program

Below is a minimal but feature-complete program demonstrating imports, constants, function definition, structs, and printing output.

```llts
# 1. Imports and constants
@const $std = @import("std/index");
@const $mem = @import("std/mem");

# 2. Setup the heap/arena
$heap = mem.create(0);

# 3. Simple function
@func add(x: i32, y: i32): i32 {
    return x + y;
}

# 4. Struct with method
@struct Counter {
    value: i32;

    @func increment(self) {
        self.value = self.value + 1;
        return self;
    }
}

# 5. Application Logic
@const $msg = "Hello, World!";
$start = 10;
$offset = 5;
$sum = add(start, offset);

# Print simple strings and formatted strings
std.debug.printLn("Message: {s}", msg);
std.debug.printLn("Initial sum: {i}", sum);

std.debug.info("Performing heap allocation...");

# Heap allocation and method chaining
$counter = @new(heap, Counter { value: sum });
$final_val = counter.increment().increment().value;

std.debug.printLn("Final counter value: {i}", final_val);
```

## 8. Key Rules & Constraints for AI Agents
1. **Declaration vs Usage:** NEVER use the `$` prefix when referencing an already declared variable (e.g., `$x = 10; $y = x + 5;` NOT `$y = $x + 5;`).
2. **Scoping & Mutability:** Use `@const $name` for imports and immutable values. Use `$name` for standard variable declaration.
3. **Escaping Local Scope:** If a struct instance is returned from a function, you MUST use `@new(heap, ...)` to allocate it on the heap.
4. **Method Receivers:** Struct methods MUST explicitly declare `self` as their first parameter.
5. **Formatting:** `std.debug.printLn` supports format strings (e.g., `{i}` for integers, `{s}` for strings).
6. **Error Handling & Logging:** Use `error(code, payload)` for structured error objects. Use `std.debug.info()`, `warn()`, and `err()` instead of `printLn` for diagnostic logging.
