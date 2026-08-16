# Shapes vs Structs (llts)

Shapes and `@struct` share the same **runtime** representation (packed field layout, object handle, `Name { … }` init), but they are **not** the same at the type level. This doc clarifies when to use each.

## Quick comparison

| | `@struct Name { … }` | `{ field: T; … }` shape | `@type Name = { … }` |
|--|--|--|--|
| Kind | Nominal product type | Structural type | Nominal name over a structural shape |
| Methods | Yes (`@func` inside the body) | No | No (data fields only; a field may have type `@func(…): R`) |
| Assignability | By name only | Structural (extra fields OK when assigning *into* a shape) | `Name` is distinct; underlying shape is structural |
| Init today | `Name { f: v, … }` or `$p: Name = { f: v, … }` | No bare `{ f: v }` without a type annotation | Same as struct (named or annotated bare init) |
| Intersection `&` | Not a shape | Yes — merge fields | Via underlying shapes |
| Runtime | Packed object | Erased to packed object when used | Same as shape / data-only struct |

**Rule of thumb:** use `@struct` when you want methods or a classic nominal record. Use shapes (`{ … }` / `@type Name = { … }`) when you want structural typing, composition with `@type`, or future `Readable & Writable`.

## `@struct` — nominal records + methods

See [Structs and Methods](structs_and_methods.md) for full syntax.

```llts
@struct Point {
    x: i64;
    y: i64;

    @func len2(self: Point): i64 {
        return self.x * self.x + self.y * self.y;
    }
}

$p = Point { x: 3, y: 4 };
print(p.len2());
```

- Two different `@struct` names are never interchangeable, even with identical fields.
- Field decls use **semicolons**; init uses **commas**.

## Object shapes — structural types

A shape is written in **type position** only:

```llts
{ value: i64; }
{ read: @func([]byte): i64; write: @func([]byte): i64; }
```

**Syntax:**

- Fields: `name: Type;` (semicolon after each field, including the last).
- Allowed wherever types appear: params, return types, annotations, `@type` / `@alias` RHS, nested in other types.

**Semantics:**

- Structural: a value is usable where shape `S` is expected if it has (at least) every field of `S` with a compatible type.
- No methods on the shape itself.
- At runtime there is **no** separate “shape” tag — layout is resolved at compile time and erased to the same packed object model as structs.

### Named shapes via `@type`

```llts
@type Pair = { a: i64; b: i64; };
$p = Pair { a: 3, b: 4 };
print(@typeOf(p));   # Pair
print(@sizeOf(Pair)); # packed size (e.g. 16)
```

This looks like a data-only `@struct`, and **codegen is the same**, but it is **not** desugared into `@struct`:

- `Pair` is a Go-style **distinct** `@type` name.
- Another `@type Other = { a: i64; b: i64; }` is a **different** type (`Pair` ≰ `Other` without `@as`).
- A `Pair` value can still satisfy an anonymous shape parameter such as `{ a: i64; }` (structural expected type).

```llts
@type A = { x: i64; };
@type B = { x: i64; };
$a = A { x: 1 };
# $b: B = a;          # error — distinct names
$b: B = @as(B, a);    # ok

@func take(p: { x: i64; }) {
    print(p.x);
}
take(a);              # ok — structural param
```

### Anonymous shapes without a typedef

Useful for APIs:

```llts
@func take(p: { x: i64; y: i64; }) {
    print(p.x);
}
```

You can construct values with a **named** init (`Point { … }`) or an **annotated bare** init when the declaration carries the type:

```llts
@type Point = { x: i64; y: i64; };
$p: Point = { x: 1, y: 2 };   # sugar for Point { x: 1, y: 2 }
```

Without a type annotation, `{ x: 1, y: 2 }` in expression position is still a **block**, not an object literal.

Shape fields with type `@func(…): R` can hold first-class function values (stored/loaded like other handles).

## `@type` / `@alias` (brief)

| Decl | Meaning |
|------|---------|
| `@type Name = T` | New **nominal** type; same layout as `T`. Need `@as` / `Name(x)` between distinct names. |
| `@alias Name = T` | Transparent rename; `Name` ≡ `T`. |

`@typeOf` prints the distinct name for `@type` values. `@sizeOf(Name)` matches the underlying layout.

`T` may be a width, pointer, array, optional, union (`|`), tuple (`[T, U]`), function type (`@func(…): R`), literal type, or **object shape**. `@struct` / `@enum` remain their own declarations; `@type` names and composes them (e.g. `@type Expr = Literal | Add`).

## When runtime is the same

For a data-only product with no methods:

```llts
@struct Pair { a: i64; b: i64; }
# vs
@type Pair = { a: i64; b: i64; };
```

Both:

- Use `Pair { a: 3, b: 4 }`
- Pack fields the same way
- Support `.a` / `.b` load/store
- Agree on `@sizeOf(Pair)` for the same field list

Prefer `@struct` if you might add methods. Prefer `@type` + shape if you care about structural params, distinct branding over the same layout, or shape intersection.

## Shape intersection `&`

```llts
@type Readable = { read: @func([]byte): i64; };
@type Writable = { write: @func([]byte): i64; };
@type Rw = Readable & Writable;
```

`&` merges object shapes (duplicate field names must agree on type). It binds tighter than `|` and is not defined on widths, unions, or `@struct` names. Lowered to a single structural shape at compile time; `@type Rw = …` stays nominal.

## Compile-time model

LLTS resolves layouts and assignability at compile time. Shape vs `@type` vs `@struct` distinctions are for the **typechecker**; the VM sees ordinary object handles and field offsets. That matches the goal that these products stay optimizable without runtime type tags for shapes.
