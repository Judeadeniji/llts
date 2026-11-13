# Primitive Widths & Scalar Types

LLTS takes a strict, honest approach to machine-level scalar types. There are no unspecified integers or implicit promotions: every numeric type specifies its bit-width, signedness, and layout semantics.

---

## 1. Numeric Widths Table

| Type | Bit Width | Byte Size | Alignment | Value Range | Aliases |
| :--- | :---: | :---: | :---: | :--- | :--- |
| `u1` | 1 | 1 | 1 | `0` or `1` (`false` or `true`) | `bool`, `boolean` |
| `i8` | 8 | 1 | 1 | `-128` to `127` | — |
| `u8` | 8 | 1 | 1 | `0` to `255` | `byte` |
| `i16` | 16 | 2 | 2 | `-32,768` to `32,767` | — |
| `u16` | 16 | 2 | 2 | `0` to `65,535` | — |
| `i32` | 32 | 4 | 4 | `-2,147,483,648` to `2,147,483,647` | — |
| `u32` | 32 | 4 | 4 | `0` to `4,294,967,295` | — |
| `i64` | 64 | 8 | 8 | `$-2^{63}$` to `$2^{63}-1$` | `int`, `number` |
| `u64` | 64 | 8 | 8 | `0` to `$2^{64}-1$` | — |
| `isize` | Platform | 8 (on 64-bit) | 8 | Signed pointer-width integer | — |
| `usize` | Platform | 8 (on 64-bit) | 8 | Unsigned pointer-width integer | — |
| `f32` | 32 | 4 | 4 | IEEE 754 single-precision float | — |
| `f64` | 64 | 8 | 8 | IEEE 754 double-precision float | `float` |
| `fsize` | Platform | 8 (on 64-bit) | 8 | Float of pointer-width (`f64`) | — |

---

## 2. Integer Semantics & Bounds Safety

### No Implicit Conversions
LLTS never implicitly widens or narrows numeric types. Assigning an `i32` to an `i64` without an explicit conversion is a compile error:

```lls
$small: i32 = 100;
# $bad: i64 = small;        # Compile Error: type mismatch
$good: i64 = @as(i64, small); # Explicit widening with @as
```

### Checked Arithmetic vs. Wrapping Operators
By default, all basic arithmetic operations (`+`, `-`, `*`) are **checked**. An overflow traps immediately at runtime:

```lls
$max: u8 = 255;
# $overflowed = max + 1;    # Traps at runtime: integer overflow
```

When two's-complement modular arithmetic is desired, use the wrapping arithmetic operators:

```lls
$wrapped = max +% 1;        # Evaluates cleanly to 0
```

| Operation | Checked (Traps on Overflow) | Wrapping (Modular Arithmetic) |
| :--- | :---: | :---: |
| **Addition** | `+` | `+%` |
| **Subtraction** | `-` | `-%` |
| **Multiplication** | `*` | `*%` |
| **Division** | `/` | — (traps on division by zero) |
| **Modulo** | `%` | — (traps on modulo by zero) |
| **Exponentiation** | `^` or `**` | — |

### Bitwise Shifts & Range Requirements
Bitwise shift operations (`<<`, `>>`) enforce strict bounds on shift amounts:

- Shift counts must be non-negative integers strictly less than 64 (`0..63`).
- Shift counts $\ge 64$ or $< 0$ trigger a runtime trap (`Shift amount out of range`).
- `>>` is an **arithmetic** (sign-extending) shift for signed integers and a logical shift for unsigned integers.
- Bitwise results preserve the left-hand operand's width.

```lls
$x: i64 = 1;
$shifted = x << 10; # Ok

# To prevent shift truncation on narrow types, widen first:
$byte_val: u8 = 0b0000_0001;
$wide_shifted = @as(i64, byte_val) << 12;
```

---

## 3. Explicit Conversions with `@as`

The `@as(TargetType, expression)` intrinsic converts a value to the target type:

```lls
$n: i64 = 42;
$as_byte = @as(u8, n);      # 42 as u8
$as_float = @as(f64, n);    # 42.0 as f64
$as_int = @as(i64, 3.14);   # 3 (truncated float-to-int)
```

### Safety and Conversion Rules:
1. **Widening conversions:** Always succeed without loss of information.
2. **Narrowing conversions:** Range-checked at runtime; if the value does not fit within the destination type's bounds, an error or trap is raised.
3. **Float to Integer:** Truncates towards zero.
4. **Integer to Float:** Converts the numeric value to the nearest representable floating-point value.

---

## 4. Special Scalar Types

### `void`
`void` represents the unit type. It signifies that a function or block produces no value:

```lls
@func log_message(msg: string): void {
    print(msg);
    return;
}
```

- Distinct from `null` (which represents the absence of a value in an optional).
- `void` is **forbidden** from appearing in union or optional types (`?void` and `i64 | void` are compile errors).

### `never`
`never` represents the bottom type — code that never returns or produces a value:

```lls
@func fatal_error(msg: string): never {
    print("FATAL:", msg);
    # In native, invokes exit syscall or abort
    @asm(```
        movq $60, %%rax
        movq $1, %%rdi
        syscall
    ```);
}
```

- Functions returning `never` guarantee that execution will not resume past the call site.
- The compiler uses `never` to recognize unreachable code branches.
- Like `void`, `never` cannot be used as an arm in union or optional types.

### `null`
`null` is both a literal and a singleton scalar type:

```lls
$x: null = null;
```

- Used primarily as an arm of optional types (`?T` is shorthand for `T | null`).
- Cannot be dereferenced or used in arithmetic.

### `type`
`type` is the first-class compile-time type of types:

```lls
@func SizeOf(T: type): i64 {
    return @sizeOf(T);
}

pub @func main() {
    print(SizeOf(i64)); # 8
}
```

- Values of type `type` can only be manipulated and evaluated at compile time.
- Used to define type functions (generic constructors).

### `unknown`
`unknown` is the gradual type used when type annotations are omitted in untyped VM mode:
- In strict mode (`--strict`), top-level functions and public bindings require explicit type annotations, ensuring gradual boundaries remain sound.
