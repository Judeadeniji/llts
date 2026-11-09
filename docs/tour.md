# A Tour of LLTS

This tour provides a guided walkthrough of LLTS syntax, type system, control flow, memory model, and systems features.

---

## 1. Bindings and Mutability

In LLTS, variables are introduced with the `$` sigil. The sigil is used **only at the declaration site**:

```lls
# Mutable variable
$count = 0;
count = count + 1;

# Immutable variable
@const $max_limit = 100;
# max_limit = 200; # Compile-time error: cannot rebind @const

# Explicit type annotation
$message: string = "Hello, LLTS!";
```

- `@const` bindings cannot be reassigned; the compiler rejects rebinding.
- Comments begin with `#` and continue to the end of the line.

See the dedicated [**Variables, Bindings & Scoping Guide**](./variables-and-bindings.md) for detailed scoping rules, labeled block expressions, and immutability invariants.

---

## 2. Honest Numeric Widths

Numeric types specify exact bit-widths without hidden promotions:

| Category | Types |
| :--- | :--- |
| **Signed Integers** | `i8`, `i16`, `i32`, `i64`, `isize` (pointer width) |
| **Unsigned Integers** | `u1` (`bool`/`boolean`), `u8` (`byte`), `u16`, `u32`, `u64`, `usize` (pointer width) |
| **Floats** | `f32`, `f64` (`float`), `fsize` |
| **Aliases** | `int` and `number` default to `i64` |

Explicit conversions use the `@as` intrinsic:

```lls
$small: i8 = 42;
$large: i64 = @as(i64, small);
$byte_val: u8 = @as(u8, 255);
```

### Unit and Bottom Types
- `void`: Indicates a function yields no value (or a bare `return;`).
- `never`: Represents unreachable code or non-returning functions (e.g. exit/abort).

---

## 3. Arrays, Slices, Tuples, and Shapes

LLTS separates fixed-size arrays from view slices and structural records:

### Sized Arrays & Slices
```lls
# Fixed-size array (length known at compile-time)
$buffer: [4]u8 = [1, 2, 3, 4];

# Slices are views over contiguous memory
$view: []u8 = buffer[1..3];   # elements 2, 3

# Slice range forms
$head = buffer[..2];          # start to index 2
$tail = buffer[2..];          # index 2 to end
$full = buffer[..];           # full slice view
```

### Heterogeneous Tuples
Tuples store a fixed sequence of mixed types and are accessed via `.0`, `.1`:

```lls
$pair: [i64, string] = [200, "OK"];
$status_code = pair.0;
$status_text = pair.1;
```

### Anonymous Structural Shapes
Shapes provide structural object types without declaring nominal structs:

```lls
$point: { x: f64; y: f64; } = { x: 10.0, y: 20.0 };
print(point.x);
```

See [**Compound Types**](./types/compound-types.md) for arrays, slices, and shapes, and [**Strings & Multiline Templates**](./strings-and-templates.md) for text and interpolation.

---

## 4. Operators and Expressions

### Checked vs Wrapping Arithmetic
Standard arithmetic traps on integer overflow. When wrapping is explicitly required, two's-complement wrapping operators are available:

```lls
$a: u8 = 250;
# $bad = a + 10;          # Traps at runtime on overflow
$wrapped = a +% 10;       # Evaluates to 4 (wrapped)
```

- Regular: `+`, `-`, `*`, `/`, `%`, `^` or `**` (power).
- Wrapping: `+%`, `-%`, `*%`.

### Bitwise Operations
Bitwise operations work on integer widths:
- `&` (AND), `|` (OR), `~` (XOR binary / NOT unary).
- `<<` (shift left), `>>` (arithmetic shift right). Shift counts must be within `0..63`.

### Null-Coalescing (`??`)
Fallback to an alternative value if the left expression evaluates to `null`:

```lls
$name: ?string = null;
$display = name ?? "Anonymous";
```

### Pipe Operator (`|>`)
The pipe operator passes the left-hand operand as the first argument of the right-hand call:

```lls
@func double(x: i64): i64 { return x * 2; }
@func add_one(x: i64): i64 { return x + 1; }

pub @func main() {
    $result = 5 |> double() |> add_one(); # add_one(double(5)) -> 11
    print(result);
}
```

See the [**Operators & Expressions Guide**](./operators-and-expressions.md) for wrapping arithmetic, bitwise shifts, compound assignment, and the full precedence table.

---

## 5. Control Flow as Expressions

Conditionals and match statements can produce values using `break <value>;`:

### Value-Producing `@if`
```lls
$temperature = 22;
$weather = @if (temperature > 20) {
    break "warm";
} @else {
    break "cool";
};
```

### Optional Payload Capture
Unwrap optional values cleanly within an `@if`:

```lls
$maybe_score: ?i64 = 95;

@if (maybe_score) |score| {
    print("Scored:", score);
} @else {
    print("No score recorded");
}
```

### Pattern Matching with `@switch`
`@switch` works across integers, strings, enums, and error sets:

```lls
$level = 2;
$title = @switch (level) {
    1 => { break "Junior"; },
    2 => { break "Mid"; },
    3 => { break "Senior"; },
    @else => { break "Unknown"; },
};
```

---

## 6. Loops and Iteration

`@for` covers ranges, conditions (while), and collections:

```lls
# 1. Range loop (exclusive upper bound)
@for (0..3) |i| {
    print("index:", i);
}

# 2. Condition loop (while-style)
$running = true;
$ticks = 0;
@for (running) {
    ticks = ticks + 1;
    @if (ticks >= 5) {
        running = false;
    }
}

# 3. Iterable loop
$items = [10, 20, 30];
@for (items) |val| {
    print("item:", val);
}
```

Loops support `break`, `continue`, and labeled forms (`break :outer;`, `continue :outer;`).

---

## 7. Structs, Methods, and Enums

### Defining Structs
Structs group fields and define methods:

```lls
@struct Vector2 {
    x: f64;
    y: f64;

    # Value receiver (copies or reads fields)
    @func length(self): f64 {
        return (self.x * self.x + self.y * self.y) ** 0.5;
    }

    # Pointer receiver (modifies the caller's struct in-place)
    @func scale(self: *Vector2, factor: f64) {
        self.x = self.x * factor;
        self.y = self.y * factor;
    }
}

pub @func main() {
    $vec = Vector2 { x: 3.0, y: 4.0 };
    print(vec.length());     # 5.0
    vec.scale(2.0);
    print(vec.x, vec.y);     # 6.0 8.0
}
```

### Enums
Enums define closed sets of named variants:

```lls
@enum Direction {
    North,
    South,
    East,
    West,
}

$dir = Direction.North;
```

---

## 8. Memory Model and Safety

LLTS uses an **explicit, frame-local stack model** for aggregates without a tracing garbage collector:

1. **Stack Allocation by Default:** Structs and fixed arrays are allocated on the caller's stack frame.
2. **Escape Analysis:** Returning a pointer to a stack-local aggregate is rejected at compile time. Only flat, scalar structs that can be safely copied may be returned by value.
3. **Deterministic Cleanup (`defer` and `errdefer`):**
   - `defer <stmt>;` runs whenever the current scope exits.
   - `errdefer <stmt>;` runs only when the scope exits via an error return.

```lls
@func process() {
    $resource = open_file();
    defer close_file(resource);

    # work with resource...
} # close_file guaranteed to run here
```

---

## 9. Error Handling

LLTS uses typed error sets and error unions rather than untyped exceptions:

```lls
@error FileError {
    NotFound,
    PermissionDenied,
}

@func read_config(path: string): string | FileError {
    @if (path == "") {
        return FileError.NotFound;
    }
    return "app_mode=debug";
}

pub @func main() {
    $result = read_config("");

    # Check for errors with @isError
    @if (@isError(result)) {
        print("Failed to read config");
    }

    # Or unwrap / propagate with '?'
    # $content = read_config("app.conf")?;
}
```

- Unwrap optionals or panic on null with `.?`.
- Propagate errors with `?`.
- Inspect errors at runtime using `@isError(expr)`.
- Create dynamic errors when needed with `error("message")`.

---

## 10. Metaprogramming and Type Functions

LLTS treats types as compile-time first-class values (`type`):

```lls
# Type introspection intrinsics
$x = 42;
print(@nameOf(@typeOf(x))); # "i64"
print(@sizeOf(i64));        # 8

# Type function (generics without templates)
@func Wrap(T: type): type {
    return { value: T; valid: bool; };
}

$boxed: Wrap(i64) = { value: 100, valid: true };
```

---

## 11. Modules and Imports

Code is organized across files using explicit relative imports:

```lls
# math.lls
pub @func square(x: i64): i64 {
    return x * x;
}

pub @const $pi = 3.14159;
```

```lls
# main.lls
@const $math = @import("./math.lls");

pub @func main() {
    print(math.square(4));
    print(math.pi);
}
```

Only symbols marked with `pub` are accessible outside their declaring file.

---

## 12. Native Hardware Access: Inline Assembly

When compiling natively (`--native`), LLTS supports GNU/Zig-style inline assembly:

```lls
pub @func main() {
    # Exit with code 42 via sys_exit (60)
    @asm(```
        movq $60, %%rax
        movq $42, %%rdi
        syscall
    ```);
}
```

See the [**Inline Assembly Guide**](./inline-assembly.md) for full documentation on constraints, register operands, and syscall calling conventions.

---

## Next Steps

- Consult the [**Language Reference**](./language-reference.md) for a comprehensive reference across declarations, control flow, memory, and types.
- Read [**Getting Started**](./getting-started.md) to set up your toolchain and build your first program.
- Explore the topic guides in the [**Documentation Portal**](./README.md).
