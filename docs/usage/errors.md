# Error Handling and Type Safety in LLTS

This document outlines the error handling mechanisms, type error detection, and safety checks built into the LLTS language. It is optimized for agents interacting with and generating LLTS code.

## Explicit Errors

The language provides an `error` builtin function to construct explicit error values.

### Syntax
```llts
@const $err = error("this is an error");
print(err);
```
- **Behavior**: Instantiates an error object with the provided message string.
- **Usage**: Error objects can be assigned to variables, printed, and returned to the host environment.

## Type System and Compile Errors

LLTS features a strict, static type system that performs checks at evaluation time. Violating type constraints results in a `CompileError`.

### Primitive Types
- **Numeric**: `int`, `i32`
- **Boolean**: `boolean`
- **Textual**: `string`, `[]byte`
  - String literals can be directly assigned to sized byte arrays. The length must match exactly.
  - Example: `$exact: [5]byte = "hello";`

### Struct and Array Type Constraints
For details on type enforcement, initialization constraints, and compile errors specific to structs and arrays, see [Structs and Methods](structs_and_methods.md) and [Arrays](arrays.md).


## Type Introspection

To programmatically check types, use the `@typeOf()` builtin macro. This is extremely useful for generating type assertions or debugging type mismatches.

```llts
print(@typeOf(p));     # Point
print(@typeOf(n));     # i32
print(@typeOf(msg));   # string
print(@typeOf(grid));  # [2][2]int
```

## Key Safety Constraints
1. **Strong Typing on Assignment**: Variables initialized with explicit types (`$var: type = ...`) will reject incompatible runtime or compile-time assignments.
2. **Strict Array Bounds**: String-to-byte-array coercion requires exact size matching (e.g., `[5]byte` for `"hello"`).
3. **Struct Mutability Constraints**: Struct fields must strictly adhere to their declared types when mutated. The type system prevents arbitrary data from corrupting defined structures.
4. **Compile-Time Evaluation**: Type errors (such as attempting to assign a `[4]byte` string to an `int`) are caught as `CompileError`s before the logical flow of execution proceeds.
