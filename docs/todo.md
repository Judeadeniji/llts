# Documentation Roadmap & Language Feature Checklist

This document tracks the documentation plan and exhaustive feature matrix for LLTS to ensure complete and structured coverage across all guides and references.

---

## 1. Documentation Architecture Plan

Target file structure for `docs/`:

- [ ] `docs/README.md` — Documentation portal, table of contents, and reading guide
- [x] `docs/getting-started.md` — Installation, toolchain requirements, CLI walkthrough, and "Hello World"
- [x] `docs/tour.md` — Fast-paced high-level tour of the language syntax and paradigms
- [x] `docs/syntax-and-grammar.md` — Lexical grammar, tokens, literals, bindings, comments, and operator precedence
- [x] `docs/types/README.md` — Type system overview and classification
- [x] `docs/types/primitive-widths.md` — Honest numeric widths (`i8`–`i64`, `u1`–`u64`, floats, `isize`/`usize`), conversions, and `@as`
- [x] `docs/types/compound-types.md` — Arrays (`[N]T`), slices (`[]T`), tuples (`[A, B]`), pointers (`*T`), and anonymous shapes (`{ ... }`)
- [x] `docs/types/algebraic-types.md` — Optionals (`?T`), unions (`A | B`), intersections (`A & B`), and flow-based narrowing
- [x] `docs/types/user-defined.md` — Nominal types (`@type`), transparent aliases (`@alias`), structs (`@struct`), and enums (`@enum`)
- [x] `docs/control-flow.md` — Conditionals (`@if`), pattern matching (`@switch`), loops (`@for`), labels, and break/continue
- [x] `docs/functions.md` — Function declarations (`@func`), parameters, variadics, methods (`self`), and first-class functions
- [x] `docs/error-handling.md` — Closed error sets (`@error`), dynamic errors, `?` propagation, `.?` unwrap, `@isError`, and `@switch` matching
- [x] `docs/memory-and-safety.md` — Frame-local stack allocation, escape analysis, `defer`, `errdefer`, and pointer rules
- [x] `docs/metaprogramming.md` — Compile-time reflection (`@typeOf`, `@sizeOf`, `@nameOf`), type functions, and `@comptime`
- [x] `docs/intrinsics.md` — Exhaustive specification of all compiler intrinsics (`@...`)
- [x] `docs/inline-assembly.md` — Native `@asm` guide, constraints, register mapping, clobbers, and verified syscalls
- [ ] `docs/modules.md` — Multi-file projects, explicit `@import`, and `pub` visibility rules
- [ ] `docs/tooling-and-cli.md` — CLI commands (`run`, `build`, `emit-zig`, `dump`), flags, bytecode VM vs native backend, and LSP

---

## 2. Exhaustive Language Feature Checklist

### Lexical Structure & Tokens
- [x] Comments: Line comments starting with `#`
- [x] Identifiers & Sigils: `$` used exclusively at declaration sites (`$x = 1;`), bare access afterwards
- [x] Integer Literals: Decimal (`42`, `1_000`), Hexadecimal (`0x2A`), Binary (`0b101010`), Octal (`0o52`)
- [x] Floating-Point Literals: Standard decimal floats (`3.14`, `1e-4`)
- [x] String Literals: Double-quoted strings with escape sequences (`"hello\n"`)
- [x] Fenced Multiline Templates: `` ```...``` `` with `${expr}` interpolation
- [x] Boolean Literals: `true`, `false`
- [x] Null Literal: `null`
- [x] Delimiters: `( )`, `{ }`, `[ ]`, `,`, `;`, `:`, `.`, `?`

### Variables, Bindings & Scoping
- [ ] Mutable Bindings: `$x = expr;`
- [ ] Immutable Bindings: `@const $x = expr;`
- [ ] Rebinding Prevention: Strict compile-time rejection when re-binding `@const`
- [ ] Explicit Type Annotations: `$x: i64 = 42;`
- [ ] Lexical Scoping: Enclosed block scopes `{ ... }`
- [ ] Labeled Block Expressions: `:label { ... break :label value; }`
- [ ] Export Modifier: `pub` visibility for module-level symbols

### Type System
- [x] **Signed Integers:** `i8`, `i16`, `i32`, `i64`, `isize` (pointer width)
- [x] **Unsigned Integers:** `u1` (alias `bool`/`boolean`), `u8` (alias `byte`), `u16`, `u32`, `u64`, `usize` (pointer width)
- [x] **Default Integer Alias:** `int` / `number` normalize to `i64`
- [x] **Floats:** `f32`, `f64` (alias `float`), `fsize`
- [x] **Unit & Bottom:**
  - [x] `void` — unit return type (no value)
  - [x] `never` — bottom type for non-returning paths
- [x] **Gradual & Reflection Types:**
  - [x] `null` — singleton type of `null`
  - [x] `type` — first-class compile-time type value
  - [x] `unknown` — gradual untyped boundary
- [x] **Compound & Structural Types:**
  - [x] `string` — immutable byte slice (`[]byte`)
  - [x] Sized Arrays: `[N]T`
  - [x] Unsized Slices: `[]T`
  - [x] Heterogeneous Tuples: `[T, U, ...]`
  - [x] Raw Pointers: `*T` and Nullable Pointers `?*T`
  - [x] Optionals: `?T` (sugar for `T | null`)
  - [x] Unions: `A | B`
  - [x] Intersections: `A & B` (shape merge or error set union)
  - [x] Anonymous Shapes: `{ field: Type, ... }`
  - [x] Function Signatures: `@func(ParamTypes): ReturnType`
- [x] **Nominal & Transparent Declarations:**
  - [x] `@type Name = T;` (distinct nominal type)
  - [x] `@alias Name = T;` (transparent type alias)
- [x] **Narrowing & Flow Typing:**
  - [x] Null narrowing via `@if` and guards
  - [x] Union narrowing via `@switch`
  - [x] Literal Type Narrowing: `const <literal>` (e.g. `const "ok"`, `const 42`)

### Operators & Expressions
- [ ] **Arithmetic (Checked):** `+`, `-`, `*`, `/`, `%`, `^` or `**` (traps on overflow)
- [ ] **Wrapping Arithmetic:** `+%`, `-%`, `*%` (two's-complement wrapping)
- [ ] **Bitwise Operators:** `&`, `|`, `~` (XOR binary / NOT unary), `<<`, `>>` (arithmetic shift)
- [ ] **Shift Range Validation:** Enforces shift count in `0..63`
- [ ] **Logical Operators:** `&&` (short-circuit), `||` (short-circuit), `!` (NOT)
- [ ] **Null-Coalescing:** `??`
- [ ] **Relational & Equality:** `==`, `!=`, `<`, `<=`, `>`, `>=`
- [ ] **Pipe Operator:** `|>` (pipes value as first argument to function call)
- [ ] **Range Operator:** `..`
- [ ] **Pattern Arrow:** `=>`
- [ ] **Compound Assignments:** `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `~=`, `<<=`, `>>=`
- [ ] **Unary Operators:** `-` (negate), `!` (logical NOT), `~` (bitwise NOT), `&` (address-of), `const` (literal assertion)
- [ ] **Postfix Operators:**
  - [ ] Member access: `.field`
  - [ ] Tuple access: `.0`, `.1`
  - [ ] Array / Slice Index: `[i]`
  - [ ] Slice Ranges: `[start..end]`, `[start..]`, `[..end]`, `[..]`
  - [ ] Optional Assertion Unwrap: `.?` (panics on null)
  - [ ] Error Try / Unwrap: `?` (propagates error or unwraps)
  - [ ] Call: `(args...)`
  - [ ] Struct Initializer: `Type { field: val, ... }`
  - [ ] Shape Initializer: `{ field: val, ... }`
- [ ] **Precedence Hierarchy:** Fully documented precedence table from assignment (1) to ranges (14)

### Control Flow
- [x] **Conditionals (`@if`):**
  - [x] Statement: `@if (cond) { ... } @else { ... }`
  - [x] Capture unwrapping: `@if (maybe_val) |val| { ... }`
  - [x] Value-producing expression: `$res = @if (cond) { break a; } @else { break b; };`
- [x] **Pattern Matching (`@switch`):**
  - [x] Statement and value-producing expression forms
  - [x] Branch patterns (literals, enums, error sets, `@else`)
  - [x] Labeled switch continue: `continue :label new_value;`
- [x] **Loops (`@for`):**
  - [x] Range loop: `@for (0..limit) |i| { ... }` (with/without capture)
  - [x] Condition loop: `@for (condition) { ... }` and infinite `@for (true) { ... }`
  - [x] Iterable loop: `@for (slice_or_array) |item| { ... }`
- [x] **Jumps:**
  - [x] `break` and labeled `break :label;` (with or without value)
  - [x] `continue` and labeled `continue :label;`
  - [x] `return expr;` and bare `return;`

### Functions & Methods
- [x] Function Declarations: `@func name(params): ReturnType { ... }`
- [x] Visibility: `pub @func`
- [x] Parameter Conventions: Type annotations, variadic/rest parameters
- [x] Struct Methods: Defined inside `@struct` bodies
- [x] Receiver Styles:
  - [x] By-value: `self`
  - [x] By-pointer: `self: *Name`
- [x] First-Class Functions: Storing, passing, and returning functions
- [x] Program Entry Point: `pub @func main() { ... }`

### Data Modeling
- [x] **Structs:**
  - [x] Declaration: `@struct Name { fields... methods... }`
  - [x] Packed and explicit layout rules
  - [x] Frame-local initialization: `Name { x: 1, y: 2 }`
- [x] **Enums:**
  - [x] Declaration: `@enum Name { VariantA, VariantB = 10, VariantC = "str" }`
  - [x] Access: `Name.VariantA`
- [x] **Tuples:**
  - [x] Product types: `[i64, string]`
  - [x] Literals: `[42, "hello"]`
  - [x] Indexing: `t.0`, `t.1`
- [x] **Anonymous Shapes:**
  - [x] Structural records: `{ x: i64; y: i64; }`
  - [x] Compatibility, structural subtyping, and intersections (`&`)

### Error Handling
- [x] **Closed Error Sets:** `@error Name { VariantA, VariantB }`
- [x] **Dynamic Errors:** `error("message")`
- [x] **Error Union Types:** `T | ErrorSet` and `T | error`
- [x] **Propagation Operator:** `expr?`
- [x] **Error Inspection Intrinsic:** `@isError(expr)`
- [x] **Error Matching:** Disjoint variant matching and handling via `@switch`

### Memory Model & Safety
- [x] **Frame-Local Stack Allocation:** Aggregates default to stack allocation
- [x] **Escape Analysis:** Compile-time validation rejecting escaping stack references
- [x] **Value Copying & Returning:** Copyable flat scalar structs vs rejected pointer escapes
- [x] **Resource Cleanup:**
  - [x] `defer <stmt>;` — runs unconditionally on scope exit
  - [x] `errdefer <stmt>;` — runs only when exiting scope on an error return path
- [x] **Pointer Mechanics:** `*T`, `?*T`, address-of operator `&`

### Metaprogramming & Compile-Time
- [x] `@typeOf(expr)` — Type introspection returning `type`
- [x] `@sizeOf(Type)` — Byte size calculation
- [x] `@nameOf(Type)` — Type display name string
- [x] `@as(TargetType, expr)` — Explicit type / width conversion
- [x] Type Functions: Generic type constructors (`@func Opt(T: type): type { return ?T; }`)
- [x] Compile-Time Blocks: `@comptime` expressions

### Compiler Intrinsics
- [x] `@import(path: string)` — Load module
- [x] `@asm(...)` — Target inline assembly
- [x] `@as(Type, expr)` — Explicit cast
- [x] `@typeOf(expr)` — Type introspection
- [x] `@sizeOf(Type)` — Size in bytes
- [x] `@nameOf(Type)` — String representation of type
- [x] `@isError(expr)` — Runtime error check
- [x] `@addrOf(expr)` — Aggregate memory address
- [x] `@concat(a, b, c)` — Byte/string concatenation
- [x] `@extern symbol;` — Foreign C symbol declaration
- [x] `@new(allocator, T)` — VM-only legacy heap allocation

### Inline Assembly (Native Backend)
- [x] Basic Assembly: `@asm("template")`
- [x] Extended Assembly: `@asm(ReturnType, ```template : outputs : inputs : clobbers```)`
- [x] Hardware registers vs named operands: `%%reg` vs `%[name]`
- [x] Operand hole binding: `${expr}`
- [x] Constraints: `"r"`, `"=r"`, `"=&r"`, `"+r"`, `"{reg}"`
- [x] Clobber specifications: `"cc"`, `"memory"`, hardware registers
- [x] Memory buffer pointers via `&buf`
- [x] Verified Linux x86-64 syscall examples (`sys_exit`, in-place modify, `sys_write`)

### Modules & Packaging
- [ ] Relative module imports via `@import("./path.lls")`
- [ ] Explicit symbol export via `pub`
- [ ] Static namespace access (`mod.Symbol`)
- [ ] Circular dependency detection and handling

### Tooling & CLI
- [ ] `llts run <file>` — VM execution
- [ ] `llts build <file> [-o output]` — Bytecode container compilation (`.llb`)
- [ ] `llts build <file> --native [-o output]` — Standalone native executable via Zig
- [ ] `llts emit-zig <file>` — Emit generated Zig source
- [ ] `llts dump <file>` — Bytecode disassembly and inspection
- [ ] CLI Flags: `--strict`, `--target`, `--optimize`, `--emit`
- [ ] Language Server: `llts-lsp` capabilities and editor integration
- [ ] Tree-sitter Grammar: `tree-sitter-llts` integration
