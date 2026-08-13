# llts-zig AST Component

This document describes the Abstract Syntax Tree (AST) structures used in `llts-zig`. The AST is designed as a strict, type-safe, and arena-allocated tree of nodes, modeled using Zig's `union(enum)`.

## Architecture Overview

The AST definitions are broken down into four main files located in `src/ast/`:

- **`root.zig`**: The central integration point. Defines the global `Node` union, the `Location` struct, and the `Document` structure that manages the lifecycle of an AST.
- **`expr.zig`**: Defines all expression-level nodes (e.g., binaries, function calls, literals, struct initializations).
- **`stmt.zig`**: Defines statement and declaration nodes (e.g., function declarations, variable declarations, control flow).
- **`types.zig`**: Defines nodes that represent type annotations (e.g., array and union types).

---

## Memory Management and Document Lifecycle

The AST is arena-allocated. The `Document` struct acts as the root container and owns an `ArenaAllocator`.

```zig
pub const Document = struct {
    path: []const u8,
    source: []const u8,
    statements: []*Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void
};
```

### Constraints & Rules for Agents
- **Lifetimes**: Every `*Node` inside `Document.statements` (and all of their child nodes) is allocated via the `Document`'s internal arena.
- **Cleanup**: Calling `document.deinit()` frees the entire tree at once.
- **Mutations**: Agents creating or modifying AST nodes must ensure they allocate new nodes using the same arena associated with the `Document`.

---

## The Core `Node` Union

Every node in the AST is represented by a single, comprehensive `union(enum)` named `Node`. This enables safe and exhaustive pattern matching across the tree.

```zig
pub const Node = union(enum) {
    declaration: Declaration,
    literal: Literal,
    primary: Primary,
    binary: Binary,
    // ... all other node types
    array_type: ArrayType,
    union_type: UnionType,

    /// Retrieves the source location for any node type
    pub fn loc(self: *const Node) Location
};
```

All concrete node structures require a `loc: Location` field, which the `.loc()` method relies on to extract line and column information.

### `Location` Type
```zig
pub const Location = struct {
    line: u32 = 0,
    column: u32 = 0,
    path: []const u8 = "",
};
```

The `path` field is leveraged by the diagnostics API (`src/errors/diag.zig`) to print precise error traces pointing back to the correct source file across multiple imports.

---

## Expressions (`expr.zig`)

Expression nodes represent values, operations, and instantiations.

### Literals & Primaries
- **`Literal`**: Represents raw values. Uses `LiteralKind` (`number`, `string`, `boolean`, `hex`, `octal`, `binary`, `null`). Has `value: []const u8` and an optional `type_name`.
- **`Primary`**: Represents basic identifiers and registers. Uses `PrimaryKind` (`identifier`, `register`, `literal`, `memory`, `immediate`).

### Operations
- **`Binary`** / **`Unary`**: Standard operations. Store `left`, `right` (or `arg`), and `operator: []const u8`.
- **`Assignment`**: Similar to binary, but specifically for assignment statements.

### Access & Invocation
- **`Call`**: `callee: *Node` and `args: []*Node`.
- **`Member`**: Property access `object.property`.
- **`Index`**: Array/Slice access `object[index]`.

### Advanced Expressions
- **`TryExpr`** / **`ErrorExpr`**: Error handling expressions.
- **`StructInit`** / **`ArrayLiteral`**: Complex initializations. `StructInit` contains a list of `StructFieldInit` values mapping names to initialized `*Node`s.

---

## Statements & Declarations (`stmt.zig`)

Statement nodes represent control flow and scope-level declarations.

### Declarations
- **`Declaration`**: Variable declarations (`const` or `var`). Tracks `is_const`, `is_public`, `value`, and an optional `type_annotation`.
- **`FunctionDecl`**: Represents functions. Contains `params` (`*Node` of type `Params`), `body`, `return_type`, and `is_public`.
- **`StructDecl`** / **`EnumDecl`**: Type definitions. `StructDecl` holds `StructField` definitions and associated `methods`.
- **`Import`** / **`Extern`**: External linkage and file imports.

### Control Flow
- **`Block`**: A scoped sequence of `statements: []*Node` with an optional `label`.
- **`If`**: Branches. Contains `condition`, `body`, optional `else_body`, and an optional `pipe_value` for capturing payloads.
- **`Switch`**: Switch expressions containing `SwitchProng`s (patterns and bodies).
- **`For`**: Loops with extensive capabilities. Differentiated by `ForKind` (`condition`, `range`, `iterable`), capable of handling range starts/ends, capture variables (`Capture`), and labels.
- **`Break`** / **`Continue`** / **`Return`** / **`Defer`**: Standard flow alterations. `Break` can optionally carry a `value`.

---

## Type Annotations (`types.zig`)

Specific nodes exist to represent types in type-annotation positions (e.g., in variable declarations or function returns).

- **`ArrayType`**: Represents `[]T` or `[N]T`.
  - `elem: *Node`: The inner type.
  - `length: ?usize`: The array size (null implies an unsized slice `[]T`).
- **`UnionType`**: Represents `T | U`.

## Summary for Agents Modifying or Analyzing the AST
1. **Pointers are pervasive**: Parent structures hold pointers (`*Node`) to children, meaning they expect heap-allocated representations (via the `Document`'s arena).
2. **Location tracking is mandatory**: Every struct requires a `loc: Location` field.
3. **Strings are slices**: Identifiers, operators, and labels are generally `[]const u8` (string slices). These slices typically point directly to the underlying `source: []const u8` in the `Document`, saving memory and reducing allocations. Do not mutate these slices.
