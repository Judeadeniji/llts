# Pointers & Low-Level Memory Mechanics

LLTS is designed with an explicit, stack-first memory architecture. Unlike languages that rely on tracing garbage collection or permissive pointer arithmetic, LLTS provides **aggregate-only capability pointers** that permit controlled in-place mutation and zero-copy data sharing while statically preventing memory safety bugs like dangling pointers, wild pointer arithmetic, and double-indirection aliasing.

---

## 1. The LLTS Pointer Philosophy

Pointers in LLTS are type-level handles that share the identity of aggregate data structures. 

### Core Safety Invariants
1. **Aggregate-Only (`&agg`):** You can only take the address of aggregate data structures (structs, sized arrays, slices). Pointers to scalar primitives (`*i64`, `*f64`) are strictly disallowed.
2. **No Pointer Arithmetic:** Expressions like `ptr + 1` or `ptr++` do not exist. Contiguous sub-ranges of memory are modeled safely using fat-pointer slices (`[]T`) with bounds checking.
3. **No Multi-Level Indirection:** Double pointers (`**T`) are forbidden. A pointer cannot point to another pointer variable.
4. **No Constant Addresses:** Taking the address of an immutable `@const` binding is rejected at compile time.
5. **Strict Frame Escape Analysis:** A pointer to a local stack-allocated aggregate cannot escape its defining stack frame. Pointers may only flow **downward** through function parameters.

---

## 2. Pointer Types & Memory Representation

LLTS defines two distinct pointer categories:

| Type | Name | Can be Null? | Description |
|---|---|:---:|---|
| `*T` | Raw Pointer | No | Non-null pointer to an aggregate of type `T` |
| `?*T` | Nullable Pointer | Yes | Optional pointer that may be either `*T` or `null` |

### Size in Memory
A pointer in LLTS occupies exactly one machine word:
```llts
@struct Point { x: i64; y: i64; }

print(@sizeOf(*Point));   # 8 bytes
print(@sizeOf(?*Point));  # 8 bytes
print(@sizeOf(*[4]u8));   # 8 bytes
```

Because null is represented as a zero address, `?*T` achieves the null-pointer optimization: `?*T` has the exact same 8-byte layout and ABI compatibility as `*T`.

---

## 3. The Address-Of Operator (`&`)

The address-of operator `&` creates a pointer handle pointing to an existing aggregate in memory:

```llts
@struct Vector {
    x: f64;
    y: f64;
}

pub @func main() {
    $v = Vector { x: 1.0, y: 2.0 };
    $p: *Vector = &v; # Creates pointer handle
    print(@typeOf(p)); # "*Vector"
}
```

### 3.1 Allowed Targets
You can take the address of:
- Nominal struct instances: `&struct_val` $\to$ `*StructName`
- Sized fixed arrays: `&array_val` $\to$ `*[N]T`
- Unsized slices: `&slice_val` $\to$ `*[]T`

### 3.2 Rejected Targets (Compile-Time Errors)

#### 1. Scalar Primitives
Taking the address of a scalar integer, float, or boolean is rejected:
```llts
$x: i64 = 42;
# COMPILE ERROR: Address-of requires an aggregate value
$p = &x; 
```
*Rationale:* In systems code, scalar values are register-allocated or stack-copied with zero overhead. Allowing arbitrary scalar pointers complicates escape analysis, aliasing analysis, and compiler register optimization.

#### 2. Existing Pointers (No `**T`)
Taking the address of a pointer is rejected:
```llts
$v = Vector { x: 1.0, y: 2.0 };
$p: *Vector = &v;
# COMPILE ERROR: Cannot take the address of a pointer
$pp = &p; 
```

#### 3. Optional Aggregates
Taking the address of an optional aggregate before unwrapping is rejected:
```llts
$maybe_v: ?Vector = Vector { x: 1.0, y: 2.0 };
# COMPILE ERROR: Cannot take the address of an optional
$p = &maybe_v; 
```

#### 4. Immutable Constants
Taking the address of a `@const` binding is rejected:
```llts
@const $ORIGIN = Vector { x: 0.0, y: 0.0 };
# COMPILE ERROR: Cannot take the address of constant
$p = &ORIGIN; 
```

---

## 4. Automatic Dereference Syntax

In LLTS, you do **not** use C-style dereference operators (`*ptr` or `ptr->field`). The compiler automatically dereferences pointer handles when accessing fields or indices:

```llts
@struct Node {
    id: i64;
    name: string;
}

pub @func main() {
    $node = Node { id: 1, name: "root" };
    $ptr: *Node = &node;

    # Direct field read (no ptr->id or (*ptr).id needed)
    print(ptr.id);   # 1
    print(ptr.name); # "root"

    # Direct field mutation
    ptr.id = 2;
    print(node.id);  # 2 (mutated in underlying struct)
}
```

### Pointer to Sized Array Indexing
Pointers to sized arrays (`*[N]T`) automatically dereference on index brackets:

```llts
$arr = [10, 20, 30];
$p_arr: *[3]i64 = &arr;

# Direct index read and write through pointer
p_arr[0] = 99;
print(arr[0]); # 99
```

---

## 5. Aliasing vs Value Copy Semantics

Understanding the difference between value assignment and pointer assignment is fundamental to LLTS memory:

```llts
@struct Box {
    value: i64;
}

pub @func main() {
    $original = Box { value: 100 };

    # 1. Value assignment: COPIES the struct
    $copied = original;
    copied.value = 200;
    print(original.value); # 100 (original is unmodified!)

    # 2. Pointer assignment: SHARES the struct identity
    $ptr = &original;
    ptr.value = 300;
    print(original.value); # 300 (original was mutated through the pointer!)

    # 3. Pointer-to-pointer assignment: creates another alias
    $alias = ptr;
    alias.value = 400;
    print(original.value); # 400 (both ptr and alias mutate the same storage)
}
```

### Rebinding Pointers
A pointer variable can be redirected to point to another aggregate of the same type:

```llts
$box_a = Box { value: 1 };
$box_b = Box { value: 2 };

$ref: *Box = &box_a;
ref.value = 10; # Mutates box_a

ref = &box_b;   # Rebind ref to box_b
ref.value = 20; # Mutates box_b

print(box_a.value, box_b.value); # 10 20
```

---

## 6. Nullable Pointers (`?*T`) & Safe Navigation

Nullable pointers allow modeling dynamic link structures such as linked lists, binary trees, and optional references.

### 6.1 Subtyping & Covariance
A non-null pointer `*T` is implicitly assignable to a nullable pointer `?*T`:

```llts
@struct Node {
    val: i64;
    next: ?*Node;
}

pub @func main() {
    $tail = Node { val: 2, next: null };
    $head = Node { val: 1, next: &tail }; # &tail (*Node) assigns to ?*Node
}
```

However, a `?*T` is **not** assignable to `*T` without an explicit check or unwrap.

### 6.2 Null Checks & Flow Narrowing

You can inspect nullable pointers using equality comparisons or flow-based guards:

```llts
@func printNext(n: *Node) {
    # 1. Null check with ==
    @if (n.next == null) {
        print("End of list");
        return;
    }

    # 2. Capture unwrapping: 'next_node' is narrowed to *Node
    @if (n.next) |next_node| {
        print("Next value:", next_node.val);
    }
}
```

### 6.3 Assertion Unwrap (`.?`)
If a nullable pointer is guaranteed to be non-null by program logic, unwrap it using `.?`:

```llts
$head = Node { val: 1, next: null };
# Panics at runtime if head.next is null:
$next_ptr: *Node = head.next.?;
```

---

## 7. Methods & Receiver Modes (`self` vs `self: *T`)

Struct methods define whether they operate on an immutable copy or an in-place mutable reference:

```llts
@struct Counter {
    val: i64;

    # Value Receiver: receives an auto-cloned stack copy
    @func read(self: Counter): i64 {
        return self.val;
    }

    # Pointer Receiver: receives a pointer handle and modifies in-place
    @func increment(self: *Counter) {
        self.val = self.val + 1;
    }
}

pub @func main() {
    $c = Counter { val: 0 };

    # Calling a pointer receiver automatically borrows &c
    c.increment();
    print(c.read()); # 1
}
```

> [!TIP]
> Callers do not need to explicitly write `(&c).increment()`. If a method requires `self: *Counter`, the compiler automatically passes the address of the caller's struct handle.

---

## 8. Compile-Time Escape Analysis (The Frame Invariant)

In LLTS, aggregates are allocated directly on the current stack frame. When a function returns, its stack frame is reclaimed.

> [!CAUTION]
> **The Escape Invariant:** A pointer to a local stack aggregate cannot be returned from a function.

```llts
@struct Point { x: i64; y: i64; }

# COMPILE ERROR: value escapes its frame region
@func createPoint(): *Point {
    $p = Point { x: 10, y: 20 };
    return &p; # REJECTED: returning pointer to local stack frame
}
```

### The Correct Architectural Pattern: Pass Downward
In LLTS, callers allocate memory on their stack frame and pass pointers **downward** into callees to populate or mutate them:

```llts
@func initializePoint(p: *Point, x: i64, y: i64) {
    p.x = x;
    p.y = y;
}

pub @func main() {
    # Caller owns the stack memory:
    $p = Point { x: 0, y: 0 };
    initializePoint(&p, 10, 20);
    print(p.x, p.y); # 10 20
}
```

---

## 9. Address Reflection & Identity Testing (`@addrOf`)

The `@addrOf(expr)` intrinsic returns the actual machine memory address (as an `i64`) of an aggregate or pointer:

```llts
@struct Target { data: i64; }

pub @func main() {
    $t1 = Target { data: 1 };
    $t2 = Target { data: 1 };
    $p1 = &t1;
    $p2 = p1;

    # Identical aliases share the exact same address
    print(@addrOf(t1) == @addrOf(p1)); # true
    print(@addrOf(p1) == @addrOf(p2)); # true

    # Separate instances have distinct memory addresses
    print(@addrOf(t1) == @addrOf(t2)); # false
}
```

---

## 10. Pointer vs Slice: Architectural Decision Guide

When should you use a raw pointer `*T` versus an unsized slice `[]T`?

| Requirement | Use `*T` (Pointer) | Use `[]T` (Slice) |
|---|:---:|:---:|
| **Target Object** | Single nominal struct instance (`*Point`) | Contiguous sequence of elements |
| **Memory Size** | Exactly 8 bytes (`*T`) | 16 bytes (`{ ptr, len }`) |
| **Slicing & Sub-views** | No | Yes (`slice[start..end]`) |
| **Recursive Data** | Linked lists, graph nodes, tree edges | Buffer chunks, text views |
| **Bounds Safety** | Single object handle | Bounds-checked index range `0..len` |
| **In-place Mutation** | Yes (`ptr.field = val`) | Yes (`slice[i] = val`) |
