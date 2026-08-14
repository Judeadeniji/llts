# llts Language Usage: Functions

This document provides technical, agent-focused documentation on defining and calling functions in the `llts` language, based on the language's reference examples. 

## Overview
Functions in `llts` are first-class constructs declared using the `@func` keyword. The language supports both optionally typed parameters and return values, as well as dynamic types. It also seamlessly handles recursion and mutual recursion.

## Function Definition Syntax

The basic syntax for a function definition is:
```llts
@func <function_name>([param1[: type], param2[: type], ...])[: return_type] {
    // Function body
    return <expression>;
}
```

### Examples
#### Fully Typed Function
Types can be explicitly annotated for both arguments and the return type.
```llts
@func add(a: i32, b: i32): i32 {
    return a + b;
}
```

#### Untyped / Dynamically Typed Function
Type annotations can be omitted completely.
```llts
@func ping(n) {
    return n;
}
```

## Arguments and Variables
*   **Variable Declarations:** Local variables inside functions (or at the top level) are instantiated with a `$` prefix (e.g., `$a = 1;`).
*   **Variable Usage:** When referencing variables in expressions or as function arguments, the `$` prefix is **omitted** (e.g., `add(a, b)`).
*   **Top-level Execution:** Top-level statements run as module initialization. The entry file must then define a zero-arg `main()`, which the compiler invokes automatically.

```llts
@func main() {
    $a = 1;         // Declaration with $
    $b = 2;
    $c = add(a, b); // Usage without $
    print(c);
}
```

## Return Statements
The `return` keyword is used to return a value from a function. If the function is untyped, it can return values of different types conditionally. If typed, the return value must match the annotated return type.

## Recursion and Mutual Recursion
`llts` fully supports recursion and mutual recursion. Functions can reference other functions that are defined later in the file without requiring forward declarations.

```llts
@func ping(n) {
    @if (n > 0) {
        return pong(n - 1); // Calls pong, which is defined below
    }
    return n;
}

@func pong(n) {
    @if (n > 0) {
        return ping(n - 1); // Mutually recursive call to ping
    }
    return n;
}
```

## Error Handling and Cleanup
Functions can return error objects and manage cleanup using `defer` and `errdefer`.

*   **Error Objects:** Created via `error("Code")` or `error("Code", payload)`. They expose `.code`, `.message`, and `.payload` properties.
*   **`defer`:** Executes a statement at the end of the current block, regardless of success or failure.
*   **`errdefer`:** Executes a statement **only** if the block exits via an error (e.g., an explicit `return error(...)` or stack unwinding via the `?` operator). Cleanups run in LIFO order.

```llts
@func process() {
    defer print("Cleanup always runs");
    errdefer print("Only runs on error");
    
    // If something fails, the `?` operator unwinds the stack, 
    // triggering errdefer (and defer) in LIFO order.
    mightFail() ?;
    
    return true; // Normal return: errdefer is skipped
}
```

## Diagnostics and Output
If an error occurs at runtime or compile-time (e.g., unresolved module imports, type errors, out-of-bounds access), LLTS will output rich diagnostics to `stderr` showing the exact source line and call stack frame (e.g., `--> file.lls:10:5`).

## Constraints and Rules for Agents
*   **Keyword Requirement:** ALWAYS use the `@func` keyword when defining a new function.
*   **Prefix Variables on Declaration:** ALWAYS use the `$` prefix when declaring/assigning a new local variable.
*   **Omit Prefix on Usage:** NEVER use the `$` prefix when referencing a previously declared variable or function parameter.
*   **No Forward Declarations:** Do not attempt to pre-declare functions. The parser handles mutual recursion directly.
