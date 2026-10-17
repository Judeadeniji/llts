# llts Array Usage Documentation

This document provides a technical overview of arrays in the `llts` language, intended for agent reference.

## 1. Initialization and Syntax
- **Array Literals**: Arrays are created using square bracket syntax with comma-separated values.
  ```llts
  # Creates a length-prefixed array literal
  $arr = [0, 0, 0, 0, 0];
  ```
- **Type**: These literals are length-prefixed under the hood, making their size retrievable at runtime.

## 2. `@new(allocator, …)` — arena allocation

Allocate into an arena (reclaim with `reset` / `deinit`):

```llts
@const $mem = @import("std/mem");
$a = mem.create(0);

# Fixed size — type is *[256]byte
$buf = @new(a, [256]byte);

# Runtime-sized mutable byte buffer (NOT the same as "hello" / std/string)
# type is *[]byte
$n = 64;
$s = @new(a, []byte, n);
# equivalent element type:
$t = @new(a, string, n);

# Runtime-sized arrays — type is *[]int
$xs = @new(a, []int, n);
$xs[0] = 7;

print(len(s));  # 64
s[0] = 65;      # OK: mutating through *[]byte (auto-deref on index)
```

`@new` always returns a **pointer** (`*T`) — same as `@new(a, Point)` → `*Point`. Indexing and field access auto-deref. Assigning an `@new` result shares the handle; frame-local `[…]` literals still copy on assign. Plain `"text"` strings are documented in [String semantics](../std/string.md#string-semantics).

Growable value arrays: `__arena_array_push(arena, arr, x)` (and `std/list` on top) extend capacity in the arena. Bare `[…]` stays frame-local fixed length.

Bare `[…]` / `Foo{}` stay **frame-local** (rewound on return) and are not individually freeable.

## 3. `std/list` / `buffer` / `map`

Prefer arena-backed std wrappers:

```llts
@const $list = @import("std/list");
@const $mem = @import("std/mem");
$a = mem.create(0);
$l = list.create(a);
list.push(l, 1);
a.reset(); # reclaim list storage
```

## 3. Indexing and assignment

- **0-Based indexing**: Elements are accessed and mutated with `array[index]`.
- **Value copy on assign**: `$b = a` shallow-copies the array; `b[i] = v` does **not** change `a`.
- **Share via pointer**: `$p = &a` yields `*[N]T` / `*[]T` (same handle); `p[i] = v` mutates `a`. Function parameters still receive a shared handle.
- **`@addrOf(x)`**: packed-heap identity as `i64` (offset). Equal for aliases (`&a` / `*T` assign); diverges after value copy. Works on aggregates and `*T` (not scalars / optionals).

  ```llts
  $a = [1, 2, 3];
  $b = a;
  b[2] = 99;
  print(a[2]);  # 3
  print(b[2]);  # 99

  $p = &a;
  p[2] = 7;
  print(a[2]);  # 7

  arr[0] = 42;
  arr[1] = 1337;

  std.fmt.printf("arr[0] = %d\n", arr[0]);
  ```

### 3.1 Bounds safety (Phase 4.4)

- **Compile-time bounds for fixed arrays**: a constant index into `[N]T` is
  checked during compilation (including `@const` and folded `+`/`-`/`*`):
  ```llts
  $a: [3]int = [1, 2, 3];
  print(a[5]);      # COMPILE ERROR: out of bounds for fixed-size array
  print(a[0 - 1]);  # COMPILE ERROR (constant fold)
  ```
- **Runtime trap for dynamic indices**: `$i = 7; a[i]` still aborts with
  `Array index out of bounds: 7 (len 3); use len(arr)` and a source location.
- **`arr.get(i): ?T`** — bounds-safe access that returns `null` instead of
  trapping. Works for arrays, slices, and strings (returns `?byte`):
  ```llts
  $a = [10, 20, 30];
  @if (a.get(1)) |v| { print(v); }   # 20
  @if (a.get(9)) |v| { print(v); } @else { print("none"); }  # none
  ```

## 4. Built-in Functions
- **`len()`**: Retrieves the length (bounds) of an array literal.
  ```llts
  $ok = std.slog.assert(len(arr) == 5);
  ```
  *(Note: `std.slog.assert` returns `null` on success and an error value on failure.)*

## 5. Advanced / Low-Level Allocation
- **Raw Heap Allocation**: If you need raw heap memory without length-prefixing overhead, use `std.mem.alloc`.
  ```llts
  $raw = std.mem.alloc(3);
  std.fmt.printf("raw ptr = %p\n", raw);
  ```
  *Note: `std.mem.alloc` returns a raw pointer rather than a standard array literal.*
