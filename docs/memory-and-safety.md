# Memory Model & Safety

LLTS is designed for systems programming without a tracing garbage collector. It employs a **frame-local region memory model** with compile-time escape analysis, explicit pointer mechanics, and deterministic scope cleanup via `defer` and `errdefer`.

---

## 1. Frame-Local Memory Model

In LLTS, aggregates (structs and fixed-size arrays) are allocated directly on the executing function's stack frame:

- **No Tracing Garbage Collector:** There is no runtime garbage collection, reference counting overhead, or unpredictable GC pause time.
- **Automatic Frame Rewind:** When a function exits, its entire stack frame is rewound and reclaimed automatically.
- **Copy on Value Assignment:** Assigning an aggregate value copies its memory. Sharing aggregate instances requires an explicit pointer (`*T`) taken with `&`.

```lls
@struct Config {
    port: i64;
    max_clients: i64;
}

pub @func main() {
    # Allocated directly on the current stack frame
    $a = Config { port: 8080, max_clients: 100 };

    # Value assignment: copies the struct
    $b = a;
    b.port = 9090;

    print(a.port); # 8080 (unchanged)
    print(b.port); # 9090
}
```

---

## 2. Compile-Time Escape Analysis

Because aggregates live on the function's stack frame, taking a reference or returning an aggregate that points to a dead frame would lead to dangling pointer bugs.

The LLTS compiler prevents this at compile time using **escape analysis**:

### Safe Returns: Flat Scalar Structs
Flat structs composed entirely of primitive scalars (`i64`, `f64`, `bool`, etc.) or nested scalar structs can be safely returned by value. The compiler auto-clones the scalar data directly onto the caller's receiving frame:

```lls
@struct Point { x: f64; y: f64; }

@func make_point(x: f64, y: f64): Point {
    $p = Point { x: x, y: y };
    return p; # Safe: flat scalar struct is cloned to caller's frame
}
```

### Rejected Returns: Escaping Frame References
If an aggregate contains pointers (`*T`) or slices (`[]T`) pointing to variables allocated on the local stack frame, returning it is strictly rejected by the compiler:

```lls
@struct BufferView {
    items: []i64;
    count: i64;
}

@func dangerous(): BufferView {
    $local_array: [2]i64 = [10, 20];
    $view = BufferView { items: local_array[..], count: 2 };
    
    # Compile Error: value escapes its frame region
    # return view;
}
```

---

## 3. Pointer Mechanics (`*T` and `&`)

Pointers provide explicit reference semantics for aggregates.

### The Pointer Model:
1. **Aggregates Only:** Pointers can point to structs (`*Point`) or fixed-size arrays (`*[4]u8`). LLTS does not permit raw pointers to scalar primitives (`*i64`) or multi-level indirection (`**T`).
2. **Borrowing with `&`:** The address-of operator `&` takes a pointer to an aggregate place:
   ```lls
   $origin = Point { x: 0.0, y: 0.0 };
   $ptr: *Point = &origin;
   ```
3. **No Address of `@const`:** You cannot take the address of an immutable binding. Attempting `&$c` on `@const $c` triggers a compile error (`Cannot take the address of constant 'c'`). A `@const` aggregate may still be sliced, but the resulting slice is a read-only view: writing through it is rejected (`Cannot mutate elements of a constant slice`).
4. **Nullable Pointers (`?*T`):** Pointers can be combined with optionals to represent nullable references (`*T | null`).

```lls
@struct Node {
    val: i64;
    next: ?*Node;
}

$first = Node { val: 1, next: null };
$second = Node { val: 2, next: &first };
```

---

## 4. Scope Cleanup: `defer` and `errdefer`

LLTS provides deterministic, scope-based cleanup mechanisms.

### `defer <statement>;`
`defer` schedules a statement to run unconditionally when the surrounding lexical block exits (whether normally, via `return`, `break`, or early exit):

```lls
@func process_transaction() {
    start_db();
    defer close_db(); # Guaranteed to run when process_transaction exits

    # Perform work...
    @if (check_condition()) {
        return; # close_db() runs before return
    }
} # close_db() runs here
```

### `errdefer <statement>;`
`errdefer` schedules a statement to run **only** if the surrounding scope exits due to an error return:

```lls
@error FileError { AccessDenied, DiskFull }

@func save_data(): void | FileError {
    $file = create_temp_file();
    errdefer delete_temp_file(file); # Runs ONLY if an error occurs!
    defer close_file(file);          # Runs ALWAYS

    write_header(file)?; # If this returns an error, delete_temp_file runs
    write_body(file)?;   # If this returns an error, delete_temp_file runs

    finalize_file(file);
    return; # On success: delete_temp_file is NOT run, close_file runs
}
```

### LIFO Execution Order
Multiple `defer` and `errdefer` statements in the same scope are executed in **Last-In, First-Out (LIFO)** reverse declaration order:

```lls
@func cleanup_demo() {
    defer print("First defer (runs second)");
    defer print("Second defer (runs first)");
}
# Output:
# Second defer (runs first)
# First defer (runs second)
```

---

## 5. Aggregate Layout Contract

Ordinary aggregates — a `@struct` without `@extern`, and an `@type` shape — share
one layout rule:

1. **Declaration order.** Fields keep the order they are written in; LLTS does
   not reorder them to pack tighter.
2. **Natural field alignment.** A field starts at the first offset that is a
   multiple of its own alignment: 1 for `u8`/`i8`/`bool`, 2 for `u16`/`i16`,
   4 for `u32`/`i32`/`f32`, 8 for `u64`/`i64`/`f64`/`usize`/`isize`/pointers and
   `string`.
3. **No blanket 8-byte minimum.** The aggregate's alignment is its widest
   field's alignment, and its size is the end of the last field rounded up to
   that alignment. Aggregates built from small fields stay small.

```lls
@struct One { a: u8; }
@struct Tiny { a: u8; b: u8; }
@struct Words { a: u32; b: u32; c: u32; }
@struct Mixed { a: u8; b: i64; c: u8; }

print(@sizeOf(One), @alignOf(One));     # 1 1
print(@sizeOf(Tiny), @alignOf(Tiny));   # 2 1
print(@sizeOf(Words), @alignOf(Words)); # 12 4
print(@sizeOf(Mixed), @alignOf(Mixed)); # 24 8
```

`Mixed` shows both effects: `b` must be 8-aligned, so seven padding bytes follow
`a`; `c` lands at offset 16 and the total is rounded up to 24. Nothing is added
for `One` and `Tiny`, which would both have been 8 bytes under a minimum-size
rule.

Because the same rule is applied by the bytecode VM and the native backend,
`@sizeOf` and `@alignOf` return the same values under `--vm` and in compiled
programs. Arrays multiply the element size exactly: `@sizeOf([100]Tiny)` is 200,
not 800, so an array of small records costs `N * @sizeOf(T)` with no per-element
slack.

`@extern @struct` declarations are the exception in intent, not in result: they
follow the platform C ABI. For the field types LLTS supports, the C ABI rule is
the same one above (declaration order, natural alignment, no minimum), so extern
structs such as `Timespec` and `Pollfd` keep their documented C sizes.

`@sizeOf` and `@alignOf` are compiler intrinsics: they are folded to integer
constants during compilation and never reach the runtime.

One backend note: `@sizeOf` always reports the LLTS layout above. The native
backend stores an ordinary aggregate in its own Zig struct type, whose internal
layout is an implementation detail and may be more compact for mixed-width
fields. That never changes the `@sizeOf`/`@alignOf` constants a program sees, nor
field access, indexing, or copies, which go through the backend's representation.

---

## Summary of Safety Invariants

| Invariant | Compiler Behavior |
| :--- | :--- |
| **No Dangling Pointers** | Escape analysis rejects returning pointers or slices to local frame variables. |
| **No Double Free / GC Pauses** | Stack frames rewind automatically on scope exit. There is no implicit heap; long-lived or shared storage must come from an explicit allocator (not yet provided by the standard library) or from OS mappings exposed by `std/syscall/memory`. |
| **Guaranteed Cleanup** | `defer` statements execute on every exit path; `errdefer` runs on error returns. |
| **Safe Immutability** | `@const` variables cannot be rebound, have their address borrowed with `&`, or be mutated through slices. |
| **Predictable Layout** | Aggregates keep declaration order and pack to natural field alignment with no 8-byte minimum; the VM and native backends report identical `@sizeOf`/`@alignOf` values. |
