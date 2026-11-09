# Modules & Organization

LLTS organizes code into discrete, self-contained files called **modules**. Every `.lls` source file is an isolated module boundary. There are no ambient globals shared between files: all cross-file dependencies are declared explicitly via the `@import` compiler intrinsic, and all external interfaces are guarded by the `pub` visibility modifier.

---

## The Module Concept

In LLTS:
- **File = Module:** Every file represents its own compilation unit and lexical scope.
- **Private by Default:** Declarations (functions, structs, enums, error sets, constants) are invisible outside their defining file unless explicitly marked `pub`.
- **Lexical Namespaces:** An `@import` expression yields a namespace aggregate. All imported symbols are accessed via member access (`mod.Symbol`), avoiding namespace collisions.
- **Deduplication:** A module is loaded, scanned, and type-checked only once per compilation session, regardless of how many times or through how many paths it is imported.

---

## Importing Modules: `@import`

Modules are loaded using the `@import` compiler intrinsic, passing a string path literal:

```llts
@const $math = @import("./math.lls");

pub @func main() {
    $sum = math.add(10, 20);
    print(sum);
}
```

> [!TIP]
> Per the project coding guidelines, top-level imports should always be declared as top-level `@const` bindings at the beginning of the file (e.g., `@const $mod = @import("./mod.lls");`).

### Path Resolution Rules

When resolving `@import("path")`:
1. **Extension Optionality:** If the `.lls` extension is omitted, the compiler automatically appends `.lls` (e.g., `@import("./math")` resolves to `./math.lls`).
2. **Current Working Directory:** The compiler first tests if the path exists relative to the current working directory (`cwd`).
3. **Workspace Root:** The compiler next checks relative to the parent directory (`../path.lls`) to accommodate standard project directory layouts.
4. **Importer-Relative Directory:** The compiler checks relative to the directory containing the current source file (`dirname(current_file)/path.lls`).

If the target module file cannot be found across any of these paths, the compiler aborts with a diagnostic:
```text
Error: Unknown module './missing.lls'
```

### Inline Imports

While top-level `@const` bindings are standard practice, `@import` is an expression and can be evaluated inline where needed:

```llts
pub @func answer(): i64 {
    return @import("./constants.lls").GLOBAL_ANSWER;
}
```

---

## Visibility: The `pub` Modifier

Everything inside a module is strictly private by default. To make an item accessible to importers, prefix its declaration with `pub`.

### Exporting Declarations

```llts
# --- file: geometry.lls ---

# Private helper: invisible to importers
@func square(n: f64): f64 {
    return n * n;
}

# Public constant
pub @const $ORIGIN = Point { x: 0.0, y: 0.0 };

# Public struct
pub @struct Point {
    x: f64;
    y: f64;

    # Methods on a pub struct are automatically accessible
    @func distance_sq(self: Point, other: Point): f64 {
        $dx = self.x - other.x;
        $dy = self.y - other.y;
        return square(dx) + square(dy);
    }
}

# Public enumeration
pub @enum Direction {
    North,
    South,
    East,
    West,
}

# Public error set
pub @error GeometryError {
    CollinearPoints,
    DegeneratePolygon,
}

# Public type alias
pub @type Coord = f64;

# Public function
pub @func distance(a: Point, b: Point): f64 {
    # Private helpers inside the module are freely accessible here
    return square(a.x - b.x) + square(a.y - b.y);
}
```

### Private Encapsulation Checks

If an importer attempts to access a symbol that is not marked `pub`, the compiler rejects it with a compile-time error:

```llts
# --- file: main.lls ---
@const $geo = @import("./geometry.lls");

pub @func main() {
    $p = geo.Point { x: 3.0, y: 4.0 }; # OK: Point is pub
    $s = geo.square(10.0);             # COMPILE ERROR: Module has no export 'square'
}
```

> [!NOTE]
> Within a struct body, methods do not require the `pub` keyword. If the `@struct` declaration itself is marked `pub`, its methods and fields are accessible to importers.

---

## Working with Imported Types

Imported structs, enums, and error sets integrate fully with LLTS's type system:

### 1. Struct Construction and Type Annotations

```llts
# --- file: buffer.lls ---
pub @struct Buffer {
    capacity: usize;
    len: usize;
}

# --- file: consumer.lls ---
@const $buf = @import("./buffer.lls");

# Using imported struct in a type annotation
pub @func process(b: *buf.Buffer) {
    # ...
}

pub @func main() {
    # Constructing an imported struct
    $b: buf.Buffer = buf.Buffer { capacity: 1024, len: 0 };
    process(&b);
}
```

### 2. Imported Enums and Exhaustive Switch

```llts
# --- file: tokens.lls ---
pub @enum TokenType {
    Keyword,
    Identifier,
    Eof,
}

# --- file: parser.lls ---
@const $tok = @import("./tokens.lls");

pub @func describe(kind: tok.TokenType): string {
    return @switch (kind) {
        tok.TokenType.Keyword    => { break "keyword"; },
        tok.TokenType.Identifier => { break "identifier"; },
        tok.TokenType.Eof        => { break "eof"; },
    };
}
```

### 3. Imported Error Sets and Propagating Calls

```llts
# --- file: io.lls ---
pub @error FileError {
    NotFound,
    PermissionDenied,
}

pub @func readFile(path: string): []u8 ! FileError {
    if (path.length == 0) {
        return FileError.NotFound;
    }
    return [0, 0, 0];
}

# --- file: app.lls ---
@const $io = @import("./io.lls");

pub @func loadConfig(): []u8 ! io.FileError {
    # Propagate imported error set using `?`
    $bytes = io.readFile("config.json")?;
    return bytes;
}
```

---

## Import Stacks and Cycle Diagnostics

When multi-file projects grow deep or contain compilation errors, LLTS traces imports through an **import stack**, unwinding from the offending file back to your entry point.

### Diagnostic Import Trace

Given three files where `main.lls` imports `mid.lls`, which imports `leaf.lls`, and `leaf.lls` has an undefined variable:

```llts
# leaf.lls
pub @func boom() {
    print(this_is_not_defined);
}
```

Compiling `main.lls` produces a hierarchical trace:

```text
Error: Unknown identifier 'this_is_not_defined'
  --> examples/import_trace/leaf.lls:3:11
   3 |     print(this_is_not_defined);
     |           ^
    at <compile> (examples/import_trace/leaf.lls:3:11)
    at @import("./leaf.lls") (examples/import_trace/mid.lls:1:16)
    at @import("./mid.lls") (examples/import_trace/main.lls:9:15)
```

This trace tells you exactly which chain of `@import` directives caused `leaf.lls` to be loaded.

### Caching and Circular Dependencies

The module loader maintains a set of visited canonical file paths:
1. When a file is encountered for the first time, its canonical path is registered.
2. If another module later imports the same file (e.g. A imports B and C; both B and C import D), the compiler reuses the already parsed document and global symbol exports for D without re-reading or re-parsing.
3. If module A imports B, and B attempts to import A while A is still active on the import stack, the module loader detects the cycle and short-circuits re-entry, preventing infinite recursion during resolution.

---

## Scope Isolation & Clean Diagnostics

The module qualifier internally namespaces exported declarations (e.g. `path/to/mod.lls::Symbol`). However, the compiler guarantees:

1. **No Variable Poisoning:** An identifier declared in an importing file (e.g. `@const $b = 99;`) will never shadow or poison a local variable named `$b` inside an imported function. Each module maintains isolated symbol environments.
2. **Display Stripping:** Type error messages and `@nameOf` introspection automatically strip internal module path prefixes for user ergonomics. An error concerning `Buffer` prints as `Buffer`, not `/home/user/project/buffer.lls::Buffer`.

---

## Project Structure Conventions

A standard LLTS application typically follows this structure:

```text
my_project/
├── build.zig          # Zig build orchestrator (if bundling native tooling)
├── src/
│   ├── main.lls       # Application entry point (`pub @func main()`)
│   ├── config.lls     # Configuration structs and defaults
│   ├── math/
│   │   ├── root.lls   # Barrel re-export module for math/
│   │   ├── vec2.lls   # 2D Vector operations
│   │   └── vec3.lls   # 3D Vector operations
│   └── util/
│       └── string.lls # String helpers
```

### The Root / Barrel Pattern

To expose a cohesive sub-library, create a `root.lls` that imports sibling modules and exposes their public APIs:

```llts
# src/math/root.lls
pub @const $vec2 = @import("./vec2.lls");
pub @const $vec3 = @import("./vec3.lls");

# src/main.lls
@const $math = @import("./math/root.lls");

pub @func main() {
    $v = math.vec2.Vec2 { x: 1.0, y: 2.0 };
}
```
