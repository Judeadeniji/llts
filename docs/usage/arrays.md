# llts Array Usage Documentation

This document provides a technical overview of arrays in the `llts` language, intended for agent reference.

## 1. Initialization and Syntax
- **Array Literals**: Arrays are created using square bracket syntax with comma-separated values.
  ```llts
  # Creates a length-prefixed array literal
  $arr = [0, 0, 0, 0, 0];
  ```
- **Type**: These literals are length-prefixed under the hood, making their size retrievable at runtime.

## 2. `@new(allocator, …)` — arena byte buffers (not string literals)

Allocate into an arena (reclaim with `reset` / `deinit`):

```llts
@const $mem = @import("std/mem");
$a = mem.create(0);

# Fixed size known at compile time
$buf = @new(a, [256]byte);

# Runtime-sized mutable byte buffer (NOT the same as "hello" / std/string)
$n = 64;
$s = @new(a, []byte, n);
# equivalent element type:
$t = @new(a, string, n);

print(len(s));  # 64
s[0] = 65;      # OK: mutating an arena []byte buffer
```

This is a **mutable length-prefixed byte array** on the heap. It is not an interned string literal and not a `std/string` slice. Plain `"text"` values and `$b = x` string assignment semantics are documented in [String semantics](../std/string.md#string-semantics).

Also: `@new(a, Point)` zero-fills structs; `@new(a, Point{ x: 1 })` / `@new(a, [1,2,3])` for explicit inits.

Bare `[…]` / `Foo{}` stay **frame-local** (rewound on return) and are not individually freeable.

## 3. Indexing and assignment

- **0-Based indexing**: Elements are accessed and mutated with `array[index]`.
- **Shared handles**: `$b = a` copies the array pointer; `b[i] = v` updates the same heap block, so `a[i]` changes too. Strings behave differently — see [String semantics](../std/string.md#string-semantics).

  ```llts
  $a = [1, 2, 3];
  $b = a;
  b[2] = 99;
  print(a[2]);  # 99

  arr[0] = 42;
  arr[1] = 1337;

  std.debug.printLn("arr[0] = {i}", arr[0]);
  ```

## 4. Built-in Functions
- **`len()`**: Retrieves the length (bounds) of an array literal.
  ```llts
  $ok = std.debug.assert(len(arr) == 5);
  ```
  *(Note: `std.debug.assert` returns `null` on success and an error value on failure.)*

## 5. Advanced / Low-Level Allocation
- **Raw Heap Allocation**: If you need raw heap memory without length-prefixing overhead, use `std.mem.alloc`.
  ```llts
  $raw = std.mem.alloc(3);
  std.debug.printLn("raw ptr = {i}", raw);
  ```
  *Note: `std.mem.alloc` returns a raw pointer rather than a standard array literal.*
