# Compound and Structural Types

LLTS provides several compound and structural types: fixed-size arrays, memory slices, heterogeneous tuples, pointers, and anonymous shapes.

---

## 1. Sized Arrays (`[N]T`)

A sized array represents a fixed-length sequence of elements of type `T` allocated contiguously on the current stack frame. The array length `N` is an integer known at compile time and is an immutable part of the array's type.

### Declaration and Initialization
```lls
# Homogeneous literal infers sized array [3]i64
$primes = [2, 3, 5];

# Explicit type annotation
$matrix: [4]f64 = [1.0, 0.0, 0.0, 1.0];
```

### Element Access & Bounds Checking
Array elements are accessed with `0`-based indices using square brackets:

```lls
$val = primes[0]; # 2
primes[1] = 7;
```

- Reading or writing out of bounds traps or triggers a compile-time/runtime error.
- Array assignment copies the array values; to pass by reference without copying, use a pointer (`*[N]T` with `&`).

---

## 2. Unsized Slices (`[]T`) and Slicing

A slice represents a dynamically-sized view into a contiguous sequence of elements. A slice value is a 16-byte fat pointer (pointer to data buffer + length).

### String & Byte Slices
`string` in LLTS is implemented as a constant byte slice (`const []u8`).

```lls
$greeting: string = "Hello, world!";
```

### Slicing Ranges (`[start..end]`)
You can create slice views using range syntax:

```lls
$text = "HelloWorld";

$sub = text[0..5];  # "Hello" (indices 0, 1, 2, 3, 4)
$tail = text[5..];  # "World" (from index 5 to end)
$head = text[..5];  # "Hello" (from start to index 5)
$full = text[..];   # "HelloWorld" (full view)
```

- `start` is inclusive; `end` is exclusive.
- Slicing bounds are checked at runtime (`Slice out of bounds` error if range exceeds length).
- Slice views over string literals and constant arrays are immutable; attempting to write through a constant slice view is rejected at compile time.

---

## 3. Heterogeneous Tuples (`[T, U, ...]`)

Tuples are fixed-length product types capable of storing distinct types in a single compound value.

### Type Inference & Literal Syntax
If an array literal contains elements of different types, LLTS automatically infers it as a tuple:

```lls
# Inferred as [i64, string]
$entry = [200, "OK"];

# Explicit type annotation
$user: [i64, string, bool] = [101, "Alice", true];
```

### Member Access
Tuple fields can be accessed using either dot-indexed access or bracket access with integer literals:

```lls
$id = user.0;     # 101
$name = user.1;   # "Alice"
$active = user.2; # true

# Or index notation:
$id_alt = user[0];
```

- Indexing beyond the tuple's declared element count is a compile-time error.
- Tuples compose cleanly with `@type` definitions:
  ```lls
  @type KeyValuePair = [string, i64];
  $pair: KeyValuePair = ["port", 8080];
  ```

---

## 4. Pointers (`*T` and `?*T`)

Pointers in LLTS provide reference semantics for **aggregate types** (structs and arrays).

### Pointer Model & Rules
1. **Pointers are for Aggregates:** Pointers point to structs (`*Point`) or arrays (`*[4]u8`). LLTS does not permit raw pointers to scalars (`*i64`) or multi-level indirection (`**T`).
2. **Value vs. Pointer Semantics:**
   - Assigning an aggregate value copies it.
   - Assigning a pointer (`*T`) or taking the address (`&place`) shares the aggregate in-place.
3. **No Address of Constants:** The address-of operator `&` cannot be applied to an immutable `@const` binding.
4. **Escape Analysis:** Pointers to local stack frames cannot escape their declaring function. Returning an aggregate pointer is rejected by the compiler.

### Syntax & Usage
```lls
@struct Config {
    port: i64;
    enabled: bool;
}

pub @func main() {
    $cfg = Config { port: 8080, enabled: true };
    $ptr: *Config = &cfg;

    # Mutating through pointer modifies original struct in-place
    ptr.port = 9090;
    print(cfg.port); # 9090
}
```

### Nullable Pointers (`?*T`)
To represent optional pointers, use `?*T` (`*T | null`):

```lls
@struct Node {
    value: i64;
    next: ?*Node;
}

$a = Node { value: 1, next: null };
$b = Node { value: 2, next: &a };
```

---

## 5. Anonymous Structural Shapes (`{ field: T; ... }`)

Shapes provide structural record typing. Unlike `@struct`, shapes do not require a declared name, and they are compared structurally rather than nominally.

### Syntax
```lls
# Declaring a shape type
@type Point = { x: f64; y: f64; };

# Initializing via shape-compatible constructor
$p: Point = Point { x: 10.0, y: 20.0 };

# Accessing fields
print(p.x, p.y);
```

The `@type` form above is a **named shape**: it has a nominal name, but its
underlying shape still participates in structural assignability with anonymous
shapes. An anonymous shape is written directly in type position:

```lls
$point: { x: f64; y: f64; } = { x: 10.0, y: 20.0 };
```

### Structural Compatibility
Functions can accept structural shapes as parameters. A source shape is
assignable to a target shape when every target field is present in the source
with a compatible type; extra source fields are allowed, and field order is not
part of assignability. Field types must be subtype-compatible, so a `u8` field
is not assignable to an `i64` field.

```lls
@type Point2D = { x: f64; y: f64; };

# Function takes an anonymous structural shape
@func display_x(obj: { x: f64; }) {
    print(obj.x);
}

$pt = Point2D { x: 3.14, y: 0.0 };
display_x(pt); # Valid: pt's underlying shape has field 'x: f64'
```

A `@struct` value is **not** structurally compatible with a shape, even when
its fields match. Structs are nominal. Two different named shapes are also
nominal and not assignable to each other; `@as` may be accepted by the
typechecker when their underlying shapes are compatible.

> The typechecker accepts structural shape rules that the native backend does
> not yet lower: a named shape passed to an anonymous-shape parameter, a shape
> with extra source fields, or a shape with a different field order may typecheck
> and run on the VM (`--vm`) but be rejected by the native backend (the default). See
> [Structs vs. Shapes](structs-vs-shapes.md) for the full compatibility matrix
> and backend limits.

### Shape Intersection (`&`)
Shapes can be intersected using the `&` operator to merge fields into a single combined type:

```lls
@type WithId = { id: i64; };
@type WithName = { name: string; };

# Entity has both 'id: i64' and 'name: string'
@type Entity = WithId & WithName;
```
