# Strings, Arrays, Slices & Tuples

LLTS provides four fundamental sequential data types for organizing linear data:
1. **Fixed-Size Sized Arrays (`[N]T`)**: Flat, contiguous, stack-allocated buffers with compile-time fixed capacity `N`.
2. **Unsized Slices (`[]T`)**: Dynamic, borrowed views over contiguous memory represented as a fat pointer (`{ ptr, len }`).
3. **Strings (`string`)**: Immutable views over UTF-8 byte sequences (`[]u8` / `[]byte`) with first-class multiline interpolation.
4. **Heterogeneous Tuples (`[T, U, ...]`)**: Fixed-length heterogeneous product types with static member access (`.0`, `.1`).

This guide covers the memory layout, type syntax, literal inference, slicing rules, mutability invariants, and escape analysis semantics for each type.

---

## 1. Architectural Comparison

| Dimension | Sized Arrays (`[N]T`) | Slices (`[]T`) | Strings (`string`) | Tuples (`[T, U, ...]`) |
|---|---|---|---|---|
| **Homogeneity** | Homogeneous (all `T`) | Homogeneous (all `T`) | Homogeneous (`u8`/`byte`) | Heterogeneous (`T`, `U`, ...) |
| **Size Bound** | Fixed at compile time (`N`) | Dynamic at runtime (`len`) | Dynamic at runtime (`len`) | Fixed at compile time ($N$ fields) |
| **Memory Layout** | Inline contiguous stack buffer | 16-byte fat pointer (`*T`, `usize`) | 16-byte fat pointer (`*u8`, `usize`) | Inline contiguous product layout |
| **Element Read** | `arr[i]` | `slice[i]` | `str[i]` (native) | `tuple.0` or `tuple[0]` |
| **Element Write** | `arr[i] = v;` | `slice[i] = v;` (in underlying memory) | Immutable | `tuple.0 = v;` |
| **Length Query** | `len(arr)` (constant-folds) | `len(slice)` | `len(str)` (constant-folds on `@const`) | Fixed tuple arity |
| **Slicable** | Yes (`arr[a..b]` yields `[]T`) | Yes (`slice[a..b]` yields `[]T`) | Yes (`str[a..b]` yields `string`) | No |
| **Iteration** | `@for (arr) \|val, idx\|` | `@for (slice) \|val, idx\|` | `@for (str) \|byte, idx\|` | Unrolled by member |
| **Stack Escape** | Returnable by value (if scalar) | Cannot escape frame if pointing to local stack | Returnable by value (borrowed view) | Returnable by value (if scalar) |

---

## 2. Fixed-Size Sized Arrays (`[N]T`)

A sized array represents a flat, contiguous sequence of $N$ elements of type $T$.

### 2.1 Type Syntax and Declaration

```llts
$numbers: [4]i64 = [10, 20, 30, 40];
$matrix_row: [3]f64 = [1.0, 2.0, 3.0];
$flags: [2]bool = [true, false];
```

The length $N$ must be a positive integer known at compile time.

### 2.2 Bidirectional Type Inference in Literals

When initializing an array with a literal:

1. **Contextual Inward Propagation:** If an explicit type annotation is provided, the element type propagates downward into the literal elements automatically. Individual element casting is redundant:
   ```llts
   # 10, 20, 30, 40 automatically infer as byte (u8)
   $bytes: [4]byte = [10, 20, 30, 40];
   ```

2. **Homogeneous Outward Inference:** If the annotation is omitted, a homogeneous literal infers as a sized array whose length matches the element count:
   ```llts
   $auto_arr = [1, 2, 3]; # Inferred as [3]i64
   ```

3. **Length Validation:** If the number of elements in the initializer literal does not equal $N$, the compiler rejects the declaration with a type error.

### 2.3 Memory Layout: Flat Stack Buffer

A sized array `[N]T` has **zero runtime overhead**:
- No garbage collector headers.
- No heap allocation pointers.
- No hidden capacity metadata.
- Total size in memory is exactly `N * @sizeOf(T)` bytes.

### 2.4 Indexing, Mutation & Bounds Checking

Elements are accessed using 0-based integer indices:

```llts
$arr = [100, 200, 300];
$second = arr[1];     # 200
arr[1] = 250;         # In-place mutation
print(arr[1]);        # 250
```

#### Runtime Bounds Checks
Every array indexing operation is bounds-checked:
- An index $< 0$ or $\ge N$ panics at runtime with:
  ```text
  Error: Array index out of bounds
  ```

#### Deep Immutability on `@const`
If an array is bound with `@const`, neither the variable nor any of its elements can be modified:

```llts
@const $ORIGIN = [0, 0];
ORIGIN[0] = 5; # COMPILE ERROR: Cannot mutate element of constant
```

### 2.5 Passing and Returning Arrays

- **By-Value Semantics:** When an array `[N]T` is passed to a function or assigned to another variable, its elements are copied:
  ```llts
  @func modify(mut: [2]i64) {
      mut[0] = 999;
  }

  pub @func main() {
      $a = [1, 2];
      modify(a);
      print(a[0]); # 1 (original is untouched)
  }
  ```
- **Returning Arrays:** A function can return a sized array by value as long as its elements are scalars (auto-cloned onto the caller's stack frame).

---

## 3. Unsized Slices (`[]T`)

A slice `[]T` is a dynamically sized, non-owning **borrowed view** over contiguous elements stored elsewhere in memory.

### 3.1 Memory Layout: The Fat Pointer

In both the VM and the native backend, a slice `[]T` is represented as a 16-byte fat pointer structure:

```text
+-----------------------+-----------------------+
|  ptr: *T (8 bytes)    |  len: usize (8 bytes) |
+-----------------------+-----------------------+
```

- `ptr`: Points directly to the first element in the backing buffer.
- `len`: Stores the active element count.

Because a slice does not own the memory it references, creating or passing slices requires **zero heap allocation and zero element copying**.

### 3.2 Slicing Range Expressions

Slices are created by slicing an array, another slice, or a string using range syntax `[start..end]`:

| Range Form | Syntax | Start Index | End Index | Resulting Length |
|---|---|---|---|---|
| **Half-Open** | `buf[start..end]` | `start` | `end` (exclusive) | `end - start` |
| **From Start** | `buf[start..]` | `start` | `len(buf)` | `len(buf) - start` |
| **Up To End** | `buf[..end]` | `0` | `end` (exclusive) | `end` |
| **Full Window** | `buf[..]` | `0` | `len(buf)` | `len(buf)` |

```llts
$arr: [5]i64 = [10, 20, 30, 40, 50];

$mid: []i64  = arr[1..4]; # elements 20, 30, 40 (len = 3)
$tail: []i64 = arr[2..];  # elements 30, 40, 50 (len = 3)
$head: []i64 = arr[..2];  # elements 10, 20 (len = 2)
$all: []i64  = arr[..];   # elements 10, 20, 30, 40, 50 (len = 5)
```

### 3.3 Bounds Verification

Slice boundaries are strictly checked at runtime:
1. `0 <= start`
2. `start <= end`
3. `end <= len(backing_buffer)`

If any invariant is violated, execution halts with a runtime trap:
```text
Error: Slice out of bounds
```

### 3.4 In-Place Mutation Through Slices

Because a slice stores a raw pointer to its backing elements, updating an element through a slice **mutates the underlying memory**:

```llts
pub @func main() {
    $buffer = [1, 2, 3, 4, 5];
    $view = buffer[1..4]; # borrows elements 2, 3, 4

    view[0] = 99;         # view[0] is buffer[1]

    print(buffer[1]);     # 99 (underlying array was modified!)
}
```

### 3.5 Escape Analysis & Stack Borrow Safety

Because slices borrow stack memory, the compiler enforces strict **compile-time escape analysis**:

> [!CAUTION]
> **Escape Invariant:** A function cannot return a slice that points into its own local stack frame. When the frame is popped at function return, that memory becomes invalid.

```llts
# COMPILE ERROR: value escapes its frame region
@func badSlice(): []i64 {
    $local_arr = [1, 2, 3];
    return local_arr[..]; # REJECTED: cannot return slice of local stack frame
}
```

Slices are designed to be passed **downward** into function calls as efficient, non-copying parameters:

```llts
@func sum(items: []i64): i64 {
    $total = 0;
    @for (items) |val| {
        total = total + val;
    }
    return total;
}

pub @func main() {
    $data = [10, 20, 30, 40];
    $res = sum(data[1..3]); # Passes view over [20, 30] without copying
    print(res);             # 50
}
```

---

## 4. Strings (`string`)

The `string` type is an immutable byte slice (`[]u8` / `[]byte`) specialized for human-readable text and ASCII/UTF-8 data.

### 4.1 String Literals & Escape Sequences

Single-line strings are enclosed in double quotes (`"..."`) or single quotes (`'...'`):

```llts
$escaped = "Line 1\nLine 2\t\"Quoted\"\0";
```

| Sequence | Character | ASCII Value |
|---|---|---|
| `\n` | Line feed / newline | 10 |
| `\r` | Carriage return | 13 |
| `\t` | Horizontal tab | 9 |
| `\\` | Backslash | 92 |
| `\"` | Double quotation mark | 34 |
| `\'` | Single quotation mark | 39 |
| `\$` | Dollar sign | 36 |
| `\0` | Null byte | 0 |
| `\xHH` | Arbitrary hex byte | Value of `HH` |

### 4.2 Multiline Fenced Templates (`` ``` ``)

For complex text, code generation, SQL queries, or formatted output, use multiline fenced templates:

````llts
$schema = ```
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL
);
```;
````

#### Precise Fencing Rules
1. **Opening Fence:** The opening `` ``` `` must be followed only by optional spaces/tabs, then an immediate newline. Body content starts on the next line.
2. **Closing Fence:** The closing `` ``` `` may be indented to align with the surrounding block. The structural semicolon `;` follows the fence.
3. **Indentation Preservation:** Interior whitespace and tabs are preserved verbatim (no arbitrary dedenting).
4. **Final Structural Newline Stripping:** Only the single trailing newline immediately preceding the closing `` ``` `` is stripped, so bodies do not gain unintended extra line breaks.
5. **Empty Templates:** An empty body evaluates to `""` with `len(s) == 0`.

### 4.3 String Interpolation: `${expr}`

Template literals support embedded expressions within `${...}` holes:

````llts
$user = "Alice";
$attempts = 3;

$alert = ```
User: ${user}
Failed Attempts: ${attempts}
Status: ${@if (attempts >= 3) { break "LOCKED"; } @else { break "ACTIVE"; }}
```;
````

- **Expressions Only:** `${...}` accepts variables, function calls, arithmetic, and control-flow expressions (`@if`, `@switch`). Declarations (`$x = 1;`) and statements are forbidden inside the hole.
- **Literal Dollars:** A bare `$` not followed by `{` is treated as a literal dollar sign (`$100` remains `$100`).
- **Escaping:** Write `\${expr}` to emit a literal `${expr}` string.
- **Compile-Time Desugaring:** The compiler translates template literals into a sequence of `@concat(...)` operations, avoiding runtime parsing overhead.

### 4.4 String Operations

#### Length (`len`)
```llts
$text = "Hello";
print(len(text)); # 5

# Compile-time evaluation on constants:
@const $STATIC_STR = "World";
@const $STATIC_LEN = len(STATIC_STR); # Evaluated at compile-time to 5
```

#### Slicing
Strings slice into sub-views without copying:
```llts
$full = "Antigravity";
$prefix = full[0..4]; # "Anti"
$suffix = full[4..];  # "gravity"
```

#### Native Byte Indexing
In the native backend, string indexing yields the underlying `u8` byte:
```llts
$greeting = "ABC";
$first: u8 = greeting[0]; # 65 (ASCII 'A')
```

#### Concatenation (`@concat`)
```llts
$joined = @concat("Host: ", "localhost", ":", "8080");
print(joined); # "Host: localhost:8080"
```

#### Equality Comparison
Strings are compared by byte content using `==` and `!=`:
```llts
$match = ("abc" == "abc"); # true
$diff  = ("abc" != "xyz"); # true
```

---

## 5. Heterogeneous Tuples (`[T, U, ...]`)

A tuple is a fixed-length, **heterogeneous** sequence where each position may hold a different type.

### 5.1 Type Syntax and Inference

Tuples are declared with brackets containing comma-separated types:

```llts
$entry: [i64, string, bool] = [1, "admin", true];
```

#### Heterogeneous Literal Disambiguation
LLTS distinguishes arrays from tuples by element homogeneity:
- **Homogeneous:** `[1, 2, 3]` infers as a sized array `[3]i64`.
- **Heterogeneous:** `[1, "hello"]` infers as a tuple `[i64, const []u8]`.

### 5.2 Element Access: Static Dot-Numeric Syntax

Tuple elements are accessed using 0-based dot-numeric syntax or constant index brackets:

```llts
$pair: [i64, string] = [404, "Not Found"];

# Property access syntax (recommended):
$code: i64 = pair.0;
$msg: string = pair.1;

# Bracket access with constant index:
$code_alt = pair[0];
$msg_alt  = pair[1];
```

#### Static Type Preservation
Each tuple element preserves its exact static type:
- `pair.0` is statically known as `i64`.
- `pair.1` is statically known as `string`.

#### Out-of-Range Protection
Accessing an element index $\ge$ tuple arity (e.g. `pair.2` on a 2-tuple) is rejected at compile time:
```text
Error: Tuple index 2 out of range for tuple '[i64, string]'
```

### 5.3 Tuple Mutation

Individual tuple elements can be updated in-place:

```llts
$record: [i64, f64] = [1, 2.5];
record.0 = 10;
record[1] = 7.5;
print(record.0, record.1); # 10 7.5
```

The compiler strictly checks assignment types. Attempting to store an incompatible type into a tuple slot produces a compile-time error:

```llts
record.0 = "text"; # COMPILE ERROR: Type 'string' is not assignable to tuple element 0 of type 'i64'
```

### 5.4 Nominal Tuples (`@type`)

To create reusable tuple types with distinct domain semantics, use `@type`:

```llts
@type Coordinates = [f64, f64];
@type Response = [u16, string];

$pos: Coordinates = [37.7749, -122.4194];
print(pos.0, pos.1);
print(@sizeOf(Coordinates)); # 16 bytes
```

### 5.5 Multi-Value Returns

Tuples provide the standard, idiomatic way to return multiple values from a function without declaring a full nominal `@struct`:

```llts
@func divide(dividend: i64, divisor: i64): [i64, i64] {
    $quotient = dividend / divisor;
    $remainder = dividend % divisor;
    return [quotient, remainder];
}

pub @func main() {
    $res = divide(17, 5);
    print("Quotient:", res.0);   # 3
    print("Remainder:", res.1);  # 2
}
```

---

## 6. The Dual-Capture `@for` Loop

LLTS provides a unified iterable `@for` loop that iterates over sized arrays, slices, and strings:

### Single Capture (Value Only)
```llts
$arr = [10, 20, 30];
@for (arr) |val| {
    print(val);
}
```

### Dual Capture (Value and Index)
By supplying two capture parameters, the loop automatically unpacks both the element value and its 0-based numeric index:

```llts
# Iterating an array with index
$items = ["alpha", "beta", "gamma"];
@for (items) |val, idx| {
    print(idx, val); # Prints: 0 alpha, 1 beta, 2 gamma
}

# Iterating string bytes with index
$greeting = "ABC";
@for (greeting) |byte_val, idx| {
    print(idx, byte_val); # Prints: 0 65, 1 66, 2 67
}

# Iterating a slice view with index
$numbers = [100, 200, 300, 400];
$window = numbers[1..3];
@for (window) |val, idx| {
    print(idx, val); # Prints: 0 200, 1 300 (idx is relative to the slice view)
}
```

> [!IMPORTANT]
> The capture order for iterable `@for` loops is always `|value, index|`.
