# Enums and Switching

This document outlines the declaration, usage, and control flow mechanics for Enums in `llts`.

## 1. Enum Declaration

Enums are **tag-only** (TypeScript-style): named variants map to auto-incrementing ints. They do **not** carry payloads.

```llts
@enum Color {
    Red,
    Green,
    Blue,
}
```

Trailing commas are allowed. For data attached to a kind, use **structs + a `kind` field** (TS discriminated unions). Planned: `Literal | Add` unions with narrowing on `kind` — see `TODO.MD` § tagged data. Not Zig-style `Variant(T)` payloads.

```llts
@enum ExprKind { Literal, Add }

@struct Literal {
    kind: ExprKind;
    value: i64;
}
```

## 2. Enum Usage and Values

```llts
$x: Color = Color.Red;
print(Color.Red == 0);      # true
print(@typeOf(Color.Blue)); # "Color"
```

Variants are zero-indexed integers. `@sizeOf(Color)` is 8.

## 3. Matching (`@switch`)

```llts
@switch (Color.Red) {
    Color.Red => { print("Red"); },
    Color.Green, Color.Blue => { print("Other"); },
    @else => { print("Unknown"); },
}
```

**Exhaustiveness:** when the scrutinee is an enum, every variant must appear in some arm **or** there must be an `@else`. Value `@switch` may omit `@else` when every variant is covered.

Arms use `break <value>;` when the `@switch` is a value expression.
