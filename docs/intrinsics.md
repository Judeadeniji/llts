# Compiler Intrinsics (`@...`)

Compiler intrinsics are built-in hooks recognized directly by the LLTS compiler front end. They provide access to low-level system facilities, compile-time type reflection, layout calculation, explicit casting, and module loading.

---

## Intrinsics Summary

| Intrinsic | Arity | Backend Support | Description |
| :--- | :---: | :---: | :--- |
| [`@import`](#import) | 1 | VM & Native | Loads a relative LLTS source module |
| [`@asm`](#asm) | 1+ | Native Only | Target-specific inline assembly |
| [`@as`](#as) | 2 | VM & Native | Explicit type casting and width conversion |
| [`@typeOf`](#typeof) | 1 | VM & Native | Compile-time type introspection |
| [`@sizeOf`](#sizeof) | 1 | VM & Native | Memory size in bytes of a type or place |
| [`@nameOf`](#nameof) | 1 | VM & Native | String identifier of a variant or symbol |
| [`@isError`](#iserror) | 1 | VM & Native | Runtime error inspection |
| [`@addrOf`](#addrof) | 1 | VM & Native | Raw memory address of an aggregate |
| [`@concat`](#concat) | 3 | VM & Native | String and byte span concatenation |
| [`@extern`](#extern) | — | VM & Native | External C symbol binding declaration |
| [`@new`](#new) | 2–3 | VM Only (Legacy) | Heap/arena allocation hook |

---

## 1. Module & Systems Intrinsics

### `@import`
Loads a relative LLTS source file as a module namespace:

```lls
@const $math = @import("./math.lls");
```

- **Signature:** `@import(path: string)`
- **Constraint:** `path` must be a compile-time string literal.
- **Return Type:** A module namespace struct containing all symbols declared with `pub` in the target file.
- **Backend:** Supported in both Bytecode VM and Native compiler.

---

### `@asm`
Embeds target-specific machine instructions directly into the native compilation stream:

#### Basic Assembly
```lls
@asm("nop");
```

#### Extended GNU/Zig-Style Assembly
```lls
$res = @asm(i64, ```
    movq %[val], %[out]
    addq $10, %[out]
    : [out] "=&r" (-> i64)
    : [val] "r" (${input})
    : "cc"
```);
```

- **Signature:** `@asm(template: string)` or `@asm(ReturnType, ```<template> : <outputs> : <inputs> : <clobbers>```)`
- **Backend:** **Native only.** The bytecode VM rejects `@asm` with a compile error.
- Full details, constraint codes, register clobbers, and syscall examples can be found in the [**Inline Assembly Guide**](./inline-assembly.md).

---

## 2. Type & Layout Introspection

### `@typeOf`
Inspects an expression at compile time and yields its static `type`:

```lls
$count: i64 = 42;
$copy: @typeOf(count) = 100;

# Used in composite types
$opt: ?@typeOf(count) = null;
```

- **Signature:** `@typeOf(expression)`
- **Return Type:** `type` (first-class compile-time type value).
- Can be used anywhere a type annotation is accepted (variables, parameters, return types, `@alias`).

---

### `@sizeOf`
Calculates the exact byte size of a type or variable place:

```lls
print(@sizeOf(i64));    # 8
print(@sizeOf(u8));     # 1
print(@sizeOf(string)); # 16 (slice view: pointer + length)

@struct Vec2 { x: f64; y: f64; }
print(@sizeOf(Vec2));   # 16
```

- **Signature:** `@sizeOf(Type | expression)`
- **Return Type:** `i64` (size in bytes).
- For compile-time types, calculates static layout size; for runtime dynamic variables, calculates storage allocation.

---

### `@nameOf`
Extracts the string identifier name of an enum variant, error set member, or named symbol:

```lls
@enum Color { Red, Blue }
@error FileError { NotFound, Denied }

pub @func main() {
    print(@nameOf(Color.Red));          # "Red"
    print(@nameOf(FileError.NotFound)); # "NotFound"
}
```

- **Signature:** `@nameOf(declaration_or_variant)`
- **Return Type:** `string`.
- **Constraint:** Expects an enum variant, error variant, or named function/variable declaration. Rejects raw literals or bare arithmetic expressions.

---

## 3. Casting & Conversion

### `@as`
Performs explicit conversions between numeric widths or distinct `@type` definitions:

```lls
# Numeric widening
$small: u8 = 10;
$big: i64 = @as(i64, small);

# Range-checked narrowing
$narrow: u8 = @as(u8, big);

# Distinct nominal type casting
@type UserId = i64;
$uid = @as(UserId, 1234);
```

- **Signature:** `@as(TargetType, expression)`
- **Return Type:** `TargetType`.
- **Safety:** Widening is lossless. Narrowing is checked against target bounds and traps if out of range.

---

## 4. Error Checking

### `@isError`
Checks at runtime whether an expression evaluates to an error:

```lls
@error ParseError { Invalid }

@func parse(s: string): i64 | ParseError {
    @if (s == "") { return ParseError.Invalid; }
    return 42;
}

pub @func main() {
    $res = parse("");
    @if (@isError(res)) {
        print("Failed to parse");
    }
}
```

- **Signature:** `@isError(expression)`
- **Return Type:** `bool` (`u1`).
- Returns `true` for typed `@error` set variants and dynamic `error("...")` instances.
- Returns `false` for normal values (`0`, `false`, `null`, empty strings).

---

## 5. Memory & Pointers

### `@addrOf`
Retrieves the memory address (integer pointer value) of an aggregate place:

```lls
@struct Point { x: f64; y: f64; }

$pt = Point { x: 1.0, y: 2.0 };
$address: i64 = @addrOf(pt);
```

- **Signature:** `@addrOf(place)`
- **Return Type:** `i64`.
- **Constraint:** Requires an aggregate place or pointer (`*T`). Does not accept optionals or primitive scalar values.

---

## 6. Strings & Concatenation

### `@concat`
Concatenates strings or stringified expressions:

```lls
$greeting = @concat(0, "Hello, ", "World!");
```

- **Signature:** `@concat(dest_placeholder, a, b)`
- **Return Type:** `string` (`[]byte`).
- Stringifies operands `a` and `b` and produces a combined byte slice. Cannot stringify `void`, `never`, or `type`.

---

## 7. External Interop

### `@extern`
Declares an external C ABI symbol for linking:

```lls
@extern "c" @func puts(str: string): i32;
```

- Binds foreign functions to be resolved during the native linking stage.

---

## 8. Legacy Allocations

### `@new` *(VM Only - Deprecated)*
Legacy heap and arena allocator hook retained for backwards compatibility with the bytecode VM:

```lls
$ptr = @new(allocator, StructType);
```

- **Backend:** Bytecode VM only.
- **Native Status:** The native backend **rejects** `@new`. Dynamic heap memory in native LLTS will be provided through standard-library allocator APIs.
