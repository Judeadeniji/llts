# Enums and Switching

This document outlines the declaration, usage, and control flow mechanics for Enums in `llts`.

## 1. Enum Declaration

Enums are declared using the `@enum` keyword. They define a collection of simple variants. 

**Syntax Rules & Constraints:**
- Variants are specified in a comma-separated list within `{}`.
- Trailing commas are allowed.
- Enums do not currently support payloads or attached data.

```llts
@enum Color {
    Red,
    Green,
    Blue,
}
```

## 2. Enum Usage and Values

**Accessing Values:**
Use dot notation on the Enum name (e.g., `Color.Red`).

**Type Annotations:**
The Enum name acts as the type for variables and function parameters.

```llts
$x: Color = Color.Red;

@func paint(c: Color) {
    print(c);
}
paint(Color.Green);
```

**Internal Representation & Introspection:**
- **Zero-Indexed Integers**: Enum variants are internally represented as `0`-indexed integers based on their declaration order. They can be directly compared against integers (`Color.Red == 0` is `true`).
- **Type Checking**: The `@typeOf(value)` builtin will return the string name of the enum (e.g., `"Color"`).

```llts
print(Color.Red == 0);      # Output: true (assuming Red is the first variant)
print(@typeOf(Color.Blue)); # Output: "Color"
```

## 3. Matching and Switching (`@switch`)

The `@switch` keyword is the primary mechanism for matching enum values, integers, and strings.

**Syntax Rules & Constraints:**
- Takes a target value enclosed in parentheses: `@switch (target) { ... }`.
- Arms follow the pattern: `MatchValue => { statement(s) }`.
- Multiple match values can be combined in a single arm using commas: `Value1, Value2 => { statement(s) }`.
- The default/fallback arm is denoted by `@else => { statement(s) }`.
- Arms are separated by commas. A trailing comma after the last arm is optional.

### Statement Switch
When used for side-effects or control flow (like `return`):

```llts
@switch (Color.Red) {
    Color.Red => { print("Red"); },
    Color.Green, Color.Blue => { print("Other"); },
    @else => { print("Unknown"); }
}
```

### Expression Switch
When `@switch` is used as an expression (e.g., assigned to a variable), you must use the `break <value>;` syntax within the arm's block to yield the result.

```llts
$c = @switch (Color.Green) {
    Color.Red => { break 100; },
    Color.Green, Color.Blue => { break 200; },
    @else => { break 0; }
};
print(c); # 200
```
