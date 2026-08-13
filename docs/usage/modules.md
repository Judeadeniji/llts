# Modules in LLTS

This document outlines the syntax, data flow, and constraints for using modules in the LLTS programming language. 

## Overview
A module in LLTS corresponds to a single `.lls` source file. Modules are used to encapsulate logic, define reusable components, and organize the codebase into namespaces.

## Importing Modules

Modules are imported using the `@import` keyword followed by a string literal path. 

### Syntax
```lls
@const $module_name = @import("path/to/module.lls");
$mutable_module = @import("path/to/other_module.lls");
```

### Constraints & Rules
- **Path format**: The path provided to `@import` is a string literal representing the file path (e.g., `"examples/import_test_lib.lls"`, `"./mid.lls"`, or `"../lib/utils.lls"`). The compiler automatically normalizes paths (resolving `.` and `..`) for reliable relative imports.
- **Return Type**: `@import` evaluates to a module object containing all of the module's exported members.
- **Assignment**: The module object must be bound to a variable (`$var = ...`) or a constant (`@const $var = ...`) to be used.
- **Member Access**: Access exported members using dot notation on the assigned module variable (e.g., `module_name.ExportedMember`).

### Diagnostics
When an error (such as a syntax error or file-not-found) occurs in an imported module, the compiler's diagnostic engine produces an `@import` stack trace. This visualizes the exact chain of imports (e.g., `main.lls` → `mid.lls` → `leaf.lls`) that led to the faulting module, making it easy to track down broken dependencies in nested hierarchies.

### Example
```lls
# import_test_main.lls
@const $std = @import("std/index");
$lib = @import("examples/import_test_lib.lls");

# Accessing a struct from the imported `lib` module
$vec = lib.Vector3 { x: 10, y: 20, z: 30 };

# Accessing a function from the standard library `std`
std.debug.printLn("Vector3: {i}, {i}, {i}", vec.x, vec.y, vec.z);
```

## Exporting Members

By default, all declarations within a module are private to that module. To expose a declaration to other modules, use the `pub` keyword.

### Syntax
```lls
# import_test_lib.lls

# Exported struct: Accessible from importing modules
pub @struct Vector3 {
    x: int;
    y: int;
    z: int;
}

# Private struct: Only accessible within this file
@struct PrivateVector {
    x: int;
}
```

### Constraints & Rules
- The `pub` keyword must precede the declaration type keyword (e.g., `pub @struct`, `pub @const`).
- Attempting to access an unexported (private) member from another module will result in a compilation error.

## Module Hierarchies (Re-exporting)

LLTS supports nested module structures (hierarchies) by allowing a module to export another imported module. 

### Syntax & Data Flow
A module can act as an `index` or facade by importing other files and exporting the resulting module objects as constants.

```lls
# std/index.lls
# Exporting submodules to create a hierarchical structure
pub @const $math = @import("std/math.lls");
pub @const $debug = @import("std/debug.lls");
pub @const $io = @import("std/io.lls");
```

When another file imports `std/index.lls`, it gains access to the nested module objects:
```lls
@const $std = @import("std/index");

# Nested access: std -> math -> add
$sum = std.math.add(5, 3);
```

## Summary for Agents
- **To Expose Code**: Prefix with `pub`. 
- **To Use Code**: Assign the result of `@import("path")` to a variable/constant.
- **To Build Hierarchies**: Re-export imported modules using `pub @const $name = @import("...");`.
