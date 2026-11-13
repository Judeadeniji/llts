# The LLTS Type System

LLTS features a sound, explicit, and compact type system designed for systems programming. It combines honest machine-level numeric widths with modern structural and algebraic type notation, compile-time escape analysis, and flow-sensitive type narrowing.

---

## Core Philosophy

1. **Honest Widths, No Implicit Conversions**  
   Every numeric type declares its exact bit-width and signedness (`i8`–`i64`, `u1`–`u64`, `f32`, `f64`). Implicit promotions and silent truncations do not exist; width conversions require explicit `@as(Target, value)` casts.

2. **Gradual at the Boundary, Sound at the Core**  
   Untyped code can execute on the bytecode VM for rapid experimentation, but strict mode (`--strict`, enabled by default for native builds) enforces sound type checking, mandatory signatures, and strict null/union safety.

3. **Structural and Nominal Coexistence**  
   - **Structural:** Tuples (`[A, B]`), slices (`[]T`), anonymous shapes (`{ x: i64; y: i64; }`), and function types (`@func(T): R`) match by their shape and composition.
   - **Nominal:** Named structs (`@struct Point`), enums (`@enum Status`), typed error sets (`@error IoError`), and distinct type definitions (`@type UserId = i64;`) enforce distinct identities that cannot be mixed without explicit conversion.

4. **Transparent vs. Nominal Aliasing**  
   - `@alias Name = T;` creates a transparent type alias (identical to `T`).
   - `@type Name = T;` creates a distinct nominal type with a unique identity (Go-style).

5. **First-Class Compile-Time Types**  
   Types are values of type `type` at compile-time. Functions can take and return types, enabling generic type constructors without separate macro or template mini-languages.

---

## Type Taxonomy

LLTS types are categorized into five primary families:

```
                                      LLTS Types
                                          │
       ┌─────────────────┬────────────────┼────────────────┬────────────────┐
       ▼                 ▼                ▼                ▼                ▼
   Primitives        Special &        Compound &       Algebraic &      User-Defined &
   & Widths           Bottom          Structural         Flow            Nominal
       │                 │                │                │                │
 • i8 .. i64       • void           • [N]T (Array)   • ?T (Optional)  • @struct
 • u1 .. u64       • never          • []T (Slice)    • A | B (Union)  • @enum
 • f32, f64        • null           • [A, B] (Tuple) • A & B (Inter.) • @error
 • isize, usize    • unknown        • *T (Pointer)   • const literal  • @type (nominal)
 • fsize           • type           • { fields }     • flow narrowing • @alias (transp.)
```

---

## Detailed Topic Guides

Dive deeper into specific areas of the LLTS type system:

1. [**Primitive Widths & Scalar Types**](primitive-widths.md)  
   Covers integer widths (`i8`–`i64`, `u1`–`u64`), floating-point precision, pointer-width types (`isize`, `usize`, `fsize`), unit (`void`), bottom (`never`), compile-time type (`type`), and explicit conversions via `@as`.

2. [**Compound & Structural Types**](compound-types.md)  
   Examines fixed-size arrays (`[N]T`), memory view slices (`[]T`), slicing syntax (`[start..end]`), heterogeneous tuples (`[A, B]`), pointers (`*T`, `?*T`), and anonymous shapes (`{ x: i64; y: i64; }`).

3. [**Algebraic Types & Type Narrowing**](algebraic-types.md)  
   Details optional types (`?T`), union types (`A | B`), structural intersection (`A & B`), forbidden union arms (`void`, `never`), optional assertion unwrap (`.?`), error try unwrap (`?`), and flow-sensitive narrowing in `@if` and `@switch`.

4. [**User-Defined Types**](user-defined.md)  
   Covers nominal structs (`@struct`), method receiver semantics (`self` vs `self: *T`), enumerations (`@enum`), closed error sets (`@error`), distinct nominal types (`@type`), and transparent aliases (`@alias`).

5. [**Structs vs. Shapes**](structs-vs-shapes.md)
   Compares nominal `@struct` records with structural shapes (`{ ... }` and `@type Name = { ... }`): type identity, assignability, methods, layout and copying, pointers, function-typed fields, and current VM/native backend limits.

---

## Type System Rules & Invariants

| Rule | Description |
| :--- | :--- |
| **No Implicit Numeric Widening** | `i32` cannot be assigned to `i64` without an explicit `@as(i64, val)`. |
| **Checked Overflow by Default** | `+`, `-`, `*` trap on integer overflow. Use `+%`, `-%`, `*%` for wrapping. |
| **Shift Count Bounds** | Shift amounts (`<<`, `>>`) must fall strictly within `0..63`. Negative or $\ge 64$ shift counts trigger runtime errors. |
| **Non-Value Union Arms Rejected** | Neither `void` nor `never` can appear in unions or optionals (`?void` and `T \| never` are compile errors). |
| **Frame-Local Aggregate Safety** | Aggregates allocate on the stack frame. Taking references that outlive the frame is rejected at compile time. |
| **Exact Field Matching on Shapes** | Anonymous shapes require field name, count, and type agreement for assignability. |
