# Operators & Expressions

LLTS provides a comprehensive operator suite designed for systems programming. Arithmetic operations are checked for overflow by default, bitwise operations are strictly bounded, and distinct wrapping operators are provided for modular arithmetic.

---

## Arithmetic Operators

### Checked Arithmetic (Default)
Standard arithmetic operators trap at runtime if an integer overflows or underflows:

| Operator | Description | Example | Overflow Behavior |
|---|---|---|---|
| `+` | Addition | `a + b` | Traps on overflow |
| `-` | Subtraction | `a - b` | Traps on underflow |
| `*` | Multiplication | `a * b` | Traps on overflow |
| `/` | Division | `a / b` | Traps on division by zero |
| `%` | Modulo / Remainder | `a % b` | Traps on division by zero |
| `^` or `**` | Exponentiation (Power) | `2 ** 3` or `2 ^ 3` | Traps on overflow |

```llts
$x: u8 = 250;
# $err = x + 10; # Runtime trap: integer overflow
```

### Wrapping Arithmetic
When two's-complement modular wrapping is intentional (e.g. hash functions, cryptography, ring buffers, random number generation), use the wrapping operators:

| Operator | Description | Example |
|---|---|---|
| `+%` | Wrapping addition | `250u8 +% 10u8 == 4u8` |
| `-%` | Wrapping subtraction | `0u8 -% 1u8 == 255u8` |
| `*%` | Wrapping multiplication | `200u8 *% 2u8 == 144u8` |

```llts
$counter: u8 = 255;
$next = counter +% 1; # Evaluates to 0 without trapping
```

---

## Bitwise Operators

Bitwise operators operate directly on integer bit representations:

| Operator | Description | Behavior |
|---|---|---|
| `&` | Bitwise AND | Sets bit if set in both operands |
| `|` | Bitwise OR | Sets bit if set in either operand |
| `~` | Bitwise XOR (Binary) | Inverts matching bits |
| `~` | Bitwise NOT (Unary) | Flips all bits |
| `<<` | Shift Left | Shifts bits left, fills with zeros |
| `>>` | Shift Right | Arithmetic shift (preserves sign bit) |

```llts
$mask: i64 = 0b0011;
$val: i64  = 0b0101;

$and_res = mask & val; # 0b0001 (1)
$or_res  = mask | val; # 0b0111 (7)
$xor_res = mask ~ val; # 0b0110 (6)
$not_res = ~mask;      # Bitwise inversion
```

### Shift Bounds Validation
- **Range Constraint:** Shift counts (`<<`, `>>`) must fall strictly within `0..63` (inclusive of 0, exclusive of 64).
- **Runtime Check:** Negative shift counts or shifts $\ge 64$ trigger a runtime panic: `Shift amount out of range`.
- **Width Preservation:** Bitwise and shift operations preserve the bit-width of their left operand. To avoid truncating high bits on narrow operands, explicitly widen before shifting:
  ```llts
  $byte_val: u8 = 0b0001;
  # Widen to i64 before shifting past 8 bits
  $shifted = @as(i64, byte_val) << 12;
  ```

---

## Comparison & Equality

Comparison operators evaluate to a boolean (`u1` / `bool`):

| Operator | Description | Supported Types |
|---|---|---|
| `==` | Equal | Primitives, enums, strings, raw pointers |
| `!=` | Not equal | Primitives, enums, strings, raw pointers |
| `<` | Less than | Numbers (`i8`–`i64`, `u8`–`u64`, floats) |
| `<=` | Less than or equal | Numbers |
| `>` | Greater than | Numbers |
| `>=` | Greater than or equal | Numbers |

```llts
$str_match = "hello" == "hello"; # true
$status = Direction.North == Direction.South; # false
```

---

## Logical Operators

Logical operators evaluate booleans and support short-circuit evaluation:

| Operator | Description | Semantics |
|---|---|---|
| `&&` | Logical AND | Short-circuits: right operand is evaluated only if left is `true` |
| `||` | Logical OR | Short-circuits: right operand is evaluated only if left is `false` |
| `!` | Logical NOT | Inverts boolean truth value |

```llts
@if (user != null && user.is_active) {
    # user.is_active is never accessed if user is null
}
```

---

## Null & Error Operators

LLTS provides dedicated operators for navigating nullable and fallible values:

### Null-Coalescing (`??`)
Yields the left expression if it is not `null`; otherwise yields the right fallback expression:

```llts
$username: ?string = null;
$display = username ?? "Guest"; # "Guest"
```

### Optional Assertion Unwrap (`.?`)
Forcibly unwraps an optional value (`?T`). If the value is `null`, execution halts immediately with a panic:

```llts
$maybe_val: ?i64 = 42;
$val: i64 = maybe_val.?; # 42 (panics if maybe_val was null)
```

### Error Try / Propagation (`?`)
Unwraps a successful value from an error union (`T ! E` or `T | E`). If the value is an error, it immediately returns the error from the enclosing function:

```llts
@func readConfig(): Config ! FileError {
    $bytes = readFile("config.json")?; # Returns early on FileError
    return parseConfig(bytes)?;
}
```

---

## The Pipe Operator (`|>`)

The pipe operator passes the value on the left as the first argument of the function call on the right:

```llts
@func square(x: i64): i64 { return x * x; }
@func increment(x: i64): i64 { return x + 1; }

pub @func main() {
    # 5 |> square() |> increment() is equivalent to increment(square(5))
    $res = 5 |> square() |> increment();
    print(res); # 26
}
```

The pipe operator chains cleanly from left to right, eliminating deep nested function call parentheses.

---

## Assignment & Compound Assignments

Variables are updated using `=` or compound assignment operators:

| Operator | Equivalent Expression |
|---|---|
| `=` | `a = b` |
| `+=` | `a = a + b` |
| `-=` | `a = a - b` |
| `*=` | `a = a * b` |
| `/=` | `a = a / b` |
| `%=` | `a = a % b` |
| `&=` | `a = a & b` |
| `|=` | `a = a \| b` |
| `~=` | `a = a ~ b` |
| `<<=` | `a = a << b` |
| `>>=` | `a = a >> b` |
| `^=` | `a = a ^ b` (power) |
| `&&=` | `a = a && b` (short-circuit) |
| `||=` | `a = a \|\| b` (short-circuit) |

> [!NOTE]
> Compound assignments are supported by the bytecode VM and the native backend. Arithmetic compounds lower through the same checked arithmetic as their expanded forms (`a += b` behaves like `a = a + b`), and bitwise/shift compounds lower directly. The native backend also supports `^=` (power) and the short-circuiting `&&=` / `||=` through the equivalent binary operations.

---

## Member, Indexing & Range Operators

| Operator | Syntax | Purpose |
|---|---|---|
| Member Access | `obj.field` | Access struct, shape, or module member |
| Tuple Access | `tuple.0`, `tuple.1` | Access heterogeneous tuple element by 0-based index |
| Indexing | `arr[i]` | Access fixed array or slice element |
| Slicing | `arr[start..end]` | Construct slice view over range (e.g. `[1..3]`, `[2..]`, `[..2]`, `[..]`) |
| Range | `start..end` | Construct range in `@for (0..10) |i|` loops |
| Pattern Arrow | `pattern => { ... }` | Match prongs in `@switch` expressions |

---

## Prefix Unary Operators

| Operator | Syntax | Purpose |
|---|---|---|
| Arithmetic Negation | `-x` | Negates numeric value |
| Logical Inversion | `!b` | Inverts boolean truth |
| Bitwise Inversion | `~n` | Inverts all integer bits |
| Address-Of | `&agg` | Obtains raw pointer (`*T`) to a stack aggregate |
| Literal Type Assertion | `const <lit>` | Narrows type to literal singleton (e.g. `const 42`, `const "ok"`) |

---

## Precedence & Associativity Hierarchy

The LLTS grammar defines 14 distinct precedence levels, evaluated from highest (14) to lowest (1):

| Level | Operators | Associativity | Description |
|:---:|:---|:---:|:---|
| **14** | `..` | None | Range constructor |
| **13** | `.field`, `.0`, `[i]`, `()`, `.?`, `?` | Left-to-right | Postfix calls, indexing, member access, unwraps |
| **12** | `-`, `!`, `~`, `&`, `const` | Right-to-left | Prefix unary operators |
| **11** | `^`, `**` | Right-to-left | Exponentiation (power) |
| **10** | `*`, `/`, `%`, `*%` | Left-to-right | Multiplicative & wrapping multiplication |
| **9** | `+`, `-`, `+%`, `-%` | Left-to-right | Additive & wrapping addition/subtraction |
| **8** | `<<`, `>>` | Left-to-right | Bitwise shift operators |
| **7** | `&` | Left-to-right | Bitwise AND |
| **6** | `~` | Left-to-right | Bitwise XOR |
| **5** | `\|` | Left-to-right | Bitwise OR |
| **4** | `<`, `<=`, `>`, `>=`, `==`, `!=` | Left-to-right | Relational & equality comparisons |
| **3** | `&&` | Left-to-right | Logical AND (short-circuiting) |
| **2** | `\|\|`, `??` | Left-to-right | Logical OR & null-coalescing |
| **1** | `\|>` | Left-to-right | Pipe operator |
| **0** | `=`, `+=`, `-=`, `*=`, `/=`, etc. | Right-to-left | Assignment and compound assignments |
