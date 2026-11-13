# Structs vs. Shapes

LLTS has two ways to describe a record: a nominal **struct** (`@struct`) and a
structural **shape** (`{ field: T; ... }`, or a named shape declared with
`@type Name = { ... };`). They share the same runtime value representation —
inline fields, value copying, and pointer access — but they have different type
identities, different assignability rules, and different method support.

This page is the reference for choosing between them and for the exact rules
the compiler applies.

---

## 1. At a Glance

| | `@struct Name` | Shape `{ ... }` / `@type Name = { ... }` |
| :--- | :--- | :--- |
| **Declaration** | `@struct Point { ... }` (no trailing `;`) | `{ x: i64; y: i64; }`, or `@type Point = { ... };` (trailing `;`) |
| **Identity** | Nominal: the declared name | Anonymous: structural, by field sequence |
| **Named form** | The name is the type | `@type` adds a nominal wrapper name |
| **Assignability** | Only to the same struct | Structural subset rules (see below) |
| **Methods** | Yes, declared in the body | No; function-typed fields are data, not methods |
| **Layout** | Inline fields in declaration order | Same inline field layout |
| **Copying** | Assignment copies the value | Assignment copies the value |
| **Pointers** | `*Name`, `?*Name` | `*Name` for a named shape; `*Shape` is VM-only today |
| **Typical use** | Domain types, invariants, methods | Structural interfaces, ad-hoc records, generic records |

> **Backend note:** the typechecker accepts structural shape rules that the
> native backend does not yet lower. The VM follows the typechecker; the native
> backend requires the exact emitted layout type. See
> [§8 Current implementation limits](#8-current-implementation-limits) before
> relying on cross-spelling shape assignments in native builds.

---

## 2. Declaring Records

### Structs

```lls
@struct Point {
    x: f64;
    y: f64;
}

pub @func main() {
    $p = Point { x: 1.0, y: 2.0 };
    print(p.x, p.y);
}
```

A struct declaration is a nominal type declaration. It is **not** followed by a
semicolon. Fields are declared by name and type; methods may be declared in the
same body.

### Anonymous shapes

A shape is written directly in type position:

```lls
$point: { x: f64; y: f64; } = { x: 10.0, y: 20.0 };
print(point.x);
```

The literal `{ x: 10.0, y: 20.0 }` is inferred from the annotation. An
unannotated literal is also allowed when the compiler can infer a shape:

```lls
$point = { x: 10.0, y: 20.0 };
print(point.x);
```

### Named shapes

A named shape is a `@type` whose underlying type is a shape:

```lls
@type Vector2 = { x: f64; y: f64; };

$v: Vector2 = Vector2 { x: 1.0, y: 2.0 };
$w: Vector2 = { x: 3.0, y: 4.0 }; # bare literal accepted
```

The trailing semicolon is required for `@type`. A named shape is a distinct
nominal name, but its underlying shape still participates in structural
assignability with anonymous shapes at typecheck time (see §3.3).

### Aliases

`@alias` is transparent and does not introduce a new identity:

```lls
@alias Point = { x: i64; y: i64; };

$p: Point = { x: 1, y: 2 };
$q: { x: i64; y: i64; } = p; # same type, both directions
```

---

## 3. Type Identity and Assignability

### 3.1 Structs are nominal

Two structs with identical fields are still different types:

```lls
@struct A { x: i64; }
@struct B { x: i64; }

$a = A { x: 1 };
$b: B = a; # compile error: type 'A' is not assignable to 'B'
```

There is no structural compatibility between a struct and a shape, even when
the fields match:

```lls
@struct Point { x: f64; y: f64; }
@func show(p: { x: f64; y: f64; }) { print(p.x); }

$p = Point { x: 1.0, y: 2.0 };
show(p); # compile error: 'Point' is not assignable to '{x: f64; y: f64}'
```

`@as` does not bridge the gap either: casting between two different structs is
rejected, and casting a struct to a shape is rejected. If you need a nominal
type with a structural interface, use a shape (or a named shape) rather than a
struct.

### 3.2 Anonymous shapes are structural

For anonymous shapes:

- **Type identity** compares field count, field order, field names, and field
  types. Two shapes with the same fields in a different order are not the same
  type.
- **Assignability** uses a subset rule: every field required by the target must
  exist in the source, with a subtype-compatible field type. Extra source
  fields are allowed, and field order is ignored for assignability.
- **No nested numeric widening:** a `u8` field is not assignable to an `i64`
  field, even though a bare `u8` value may widen to `i64` in an assignment.
  Width conversion inside a shape requires an explicit `@as` on the field.

```lls
@func take(s: { x: i64; }) { print(s.x); }

$p: { x: i64; y: i64; } = { x: 1, y: 2 };
take(p); # accepted by the typechecker: 'p' has the required field 'x'

$q: { x: u8; } = { x: 2 };
take(q); # compile error: 'u8' is not a subtype of 'i64'
```

Field order is accepted for assignability:

```lls
@func take(s: { y: i64; x: i64; }) { print(s.x); }
$p: { x: i64; y: i64; } = { x: 1, y: 2 };
take(p); # typechecker: accepted (order is not part of assignability)
```

### 3.3 Named shapes

`@type Name = { ... };` creates a distinct named type whose underlying type is
a shape. It has two relevant properties:

1. **Between two named shapes**, identity is by name. `A` and `B` are not
   assignable, even with identical fields. `@as(B, a)` is accepted by the
   typechecker when the underlying shapes are compatible, but the native
   backend currently rejects it.
2. **Between a named shape and an anonymous shape**, the underlying shape rules
   apply. A named shape value can be used where an anonymous shape is expected
   (and vice versa) at typecheck time.

```lls
@type Point = { x: i64; y: i64; };
@func showX(p: { x: i64; }) { print(p.x); }

$p = Point { x: 1, y: 2 };
showX(p); # typechecker: accepted (underlying shape has 'x')

$n: Point = { x: 3, y: 4 }; # accepted: literal is checked against Point
```

### 3.4 Typecheck assignability matrix

The table below describes the **typechecker** result. The VM follows this table;
the native backend has additional layout restrictions (§8).

| Source | Target | Result |
| :--- | :--- | :--- |
| `@struct S` | same `S` | Assignable |
| `@struct S` | different struct, even with same fields | Not assignable; `@as` not allowed |
| `@struct S` | anonymous shape or named shape | Not assignable; `@as` not allowed |
| Anonymous shape | identical anonymous shape | Assignable |
| Anonymous shape | anonymous shape with a subset of fields | Assignable (extra source fields allowed) |
| Anonymous shape | anonymous shape with extra required fields | Not assignable |
| Anonymous shape | named shape | Assignable at typecheck; literal initializers also work |
| Named shape | same named shape | Assignable |
| Named shape | different named shape, even with same fields | Not assignable; `@as` typechecks |
| Named shape | anonymous shape with the same fields or a subset | Assignable at typecheck |
| Named shape | anonymous shape requiring missing fields | Not assignable |
| `@alias` shape | anonymous or named shape | Follows the anonymous-shape rules |

Concrete differences to remember:

- `A` → `B` where both are `@type` shapes: the compiler suggests
  `@as(B, a)`. The suggestion typechecks, but it is not a native-build fix
  today.
- `{ x, y }` → `{ x }`: accepted by the typechecker (width/subset rule), but
  native codegen rejects the layout mismatch.
- `{ y, x }` → `{ x, y }`: accepted by the typechecker, but native codegen
  rejects the different field order.

---

## 4. Methods

Methods are a struct-only feature. They are declared inside the `@struct` body,
and the first parameter is the receiver:

```lls
@struct Counter {
    count: i64;

    @func add(self, delta: i64): Counter {
        return Counter { count: self.count + delta };
    }

    @func bump(self: *Counter) {
        self.count = self.count + 1;
    }
}

pub @func main() {
    $c = Counter { count: 10 };
    $u = c.add(5);  # value receiver: returns a new Counter
    c.bump();       # pointer receiver: mutates c
    print(u.count, c.count);
}
```

Shapes do not have a method body. A `@func` inside a shape type is a parse
error:

```lls
@type Shape = {
    x: i64;
    @func get(self): i64 { # parse error: shapes do not declare methods
        return self.x;
    }
};
```

### Function-typed fields are not methods

A shape can store a function value in a field, and the field can be called with
dot syntax:

```lls
@type Adder = { add: @func(i64): i64; };

@func inc(x: i64): i64 { return x + 1; }

pub @func main() {
    $a = Adder { add: inc };
    print(a.add(1)); # 2
}
```

This is a data field containing a function pointer, not a method declaration.
The field can be reassigned, passed around, and stored independently of the
record type. See §7 for backend differences in how function-typed fields are
called.

### Methods on generic structs

Generic struct declarations are written with type parameters in parentheses, not
square brackets:

```lls
@struct Pair(A: type, B: type) {
    first: A;
    second: B;

    @func swap(self): Pair(B, A) {
        return Pair(B, A) { first: self.second, second: self.first };
    }
}
```

Every distinct argument list is its own nominal struct, with its own methods.

---

## 5. Layout, Values, and Pointers

### Inline fields and alignment

Structs and shapes use the same value representation: fields are stored inline
in declaration order, with normal machine alignment. There is no hidden
indirection or header.

```lls
@type A = { a: u8; b: i64; };
@type B = { b: i64; a: u8; };
@type C = { a: u8; b: u8; };
@type D = { xs: [3]i64; };

print(@sizeOf(A), @sizeOf(B), @sizeOf(C), @sizeOf(D)); # 16 16 8 24
```

The same layout rules apply to `@struct`:

```lls
@struct S { a: u8; b: i64; }
print(@sizeOf(S)); # 16
```

A function-typed field is a pointer-sized value (8 bytes on a 64-bit target):

```lls
@type Handler = { run: @func(): int; };
print(@sizeOf(Handler)); # 8
```

### Assignment copies

Assigning a struct or shape value copies its fields; the source is unchanged:

```lls
@type P = { x: i64; y: i64; };
@struct S { x: i64; y: i64; }

$a: P = { x: 1, y: 2 };
$b = a;
b.x = 9;
print(a.x, b.x); # 1 9

$c: S = { x: 1, y: 2 };
$d = c;
d.x = 9;
print(c.x, d.x); # 1 9
```

To share a value in place, take a pointer with `&`:

```lls
$p: P = { x: 1, y: 2 };
$ptr = &p;
ptr.x = 9;
print(p.x); # 9
```

### `const` records

A `@const` record is immutable: its fields cannot be assigned. This is a compile
error for both structs and shapes:

```lls
@type P = { x: i64; };
@const $ORIGIN: P = { x: 1 };

ORIGIN.x = 2; # compile error: cannot mutate field of constant
```

### Pointers

Pointers are aggregate-only and support automatic field access:

```lls
@type P = { x: i64; y: i64; };
@struct S { x: i64; y: i64; }

@func readP(p: *P) { print(p.x); }
@func readS(p: *S) { print(p.x); }

pub @func main() {
    $p: P = { x: 1, y: 2 };
    $s: S = { x: 3, y: 4 };
    readP(&p);
    readS(&s);
}
```

`*P` for a named shape works on both backends. A pointer to an *anonymous*
shape (`*{ x: i64; }`) is accepted by the typechecker and runs on the VM, but
the native backend currently rejects it (`Cannot access field 'x' on type
'*{x: i64}'`). Prefer a named shape when a pointer type is needed.

### Recursive records

Both forms support recursion through an optional self-pointer:

```lls
@type Node = {
    value: i64;
    next: ?*Node;
};

@struct ListNode {
    value: i64;
    next: ?*ListNode;
}
```

### Nesting and composition

Shapes and structs nest freely as field types, in either direction:

```lls
@type Inner = { x: i64; };
@struct Outer {
    inner: Inner;
    anon: { y: i64; };
}
```

Shapes can be produced by type functions, which is how LLTS expresses generic
records without template syntax:

```lls
@func Pair(T: type): type {
    return { first: T; second: T; };
}

$p: Pair(i64) = { first: 1, second: 2 };
```

Shape intersections (`&`) merge fields and work with named shapes:

```lls
@type WithId = { id: i64; };
@type WithName = { name: string; };
@type Entity = WithId & WithName;

$e: Entity = { id: 1, name: "a" };
```

---

## 6. Reflection and Formatting

`@sizeOf` and `@typeOf` treat both forms uniformly:

```lls
@struct Point { x: i64; y: i64; }
@type Shape = { x: i64; y: i64; };

$p = Point { x: 1, y: 2 };
$s = Shape { x: 1, y: 2 };
$a: { x: i64; y: i64; } = { x: 1, y: 2 };

print(@sizeOf(Point), @sizeOf(Shape)); # 16 16
print(@typeOf(p), @typeOf(s), @typeOf(a));
# Point
# Shape
# {x: i64; y: i64}
```

Formatting differs by backend:

- **Native:** `print` uses the declared name and field values:
  `Point { x: 1, y: 2, }`, `Shape { ... }`, or `{ x: 1, y: 2, }` for an
  anonymous shape.
- **VM:** aggregate values are represented as byte objects, so `print`
  currently emits the raw bytes rather than a field listing. Print fields
  individually on the VM (`print(p.x, p.y)`) for readable output.

`@nameOf` is intended for enum/error variants and named declarations; it does
not accept a `type` value produced by `@typeOf`. Use `@typeOf` directly to
inspect a value's type.

---

## 7. Function-Typed Fields and Backend Behavior

Function-typed fields are ordinary fields whose type is `@func(...)`. Their
behavior depends on whether the function is a top-level function pointer or a
closure literal, and on whether the call is used as an expression or a
statement.

| Case | Typecheck | VM | Native |
| :--- | :--- | :--- | :--- |
| Top-level function pointer field, called in an expression | Accept | Runs | Runs |
| Top-level function pointer field, `void` call as a statement | Accept | Runs | Codegen error |
| Closure literal stored in a field, called in an expression | Accept | Runtime error | Runs |
| Capturing closure stored in a field, called in an expression | Accept | Runtime error | Runs |
| Closure returned from a function, then called | Accept | Runtime error | Runs |

Examples:

```lls
# Top-level function pointer: works on both backends.
@type Adder = { add: @func(i64): i64; };
@func inc(x: i64): i64 { return x + 1; }

$adder = Adder { add: inc };
print(adder.add(1)); # 2

# Closure literal in a field: native works, VM does not.
$closureAdder = Adder {
    add: @func(x: i64): i64 { return x + 1; },
};
print(closureAdder.add(1)); # native: 2; VM: runtime error
```

The VM error for closure-valued fields is
`Packed field access requires a byte object, got 'func'` (or `got 'int'` for a
capturing closure). The native backend does not support a `void` function-field
call written as a statement; use an expression context or a top-level function
pointer when targeting native.

---

## 8. Current Implementation Limits

The typechecker implements structural shape assignability. The native backend
lowers each distinct display spelling to its own emitted Zig struct, so it
currently requires the expected and actual values to have the same emitted
layout type. The VM has no such layout-identity restriction.

| Case | Typecheck | VM | Native |
| :--- | :--- | :--- | :--- |
| Struct → shape (same fields) | Reject | Reject | Reject |
| Anonymous shape → named shape (value) | Accept | Runs | Reject |
| Named shape → anonymous shape (value) | Accept | Runs | Reject |
| Anonymous shape → anonymous shape with extra source fields | Accept | Runs | Reject |
| Anonymous shape → anonymous shape with different field order | Accept | Runs | Reject |
| Named shape → different named shape (same fields) | Reject; `@as` accepts | Runs after `@as` | `@as` rejects |
| Pointer to an anonymous shape | Accept | Runs | Reject |
| Void function-field call as a statement | Accept | Runs | Reject |
| Closure literal in a field, called | Accept | Reject | Runs |
| Capturing closure returned and called | Accept | Reject | Runs |
| Printing an aggregate value | n/a | Raw bytes | Named/structured output |

Practical guidance:

- For native builds, keep the **exact shape spelling** on both sides of a
  boundary. If a function expects `{ x: i64; y: i64; }`, pass a value declared
  as `{ x: i64; y: i64; }` (or a literal), not a named shape.
- If a named shape must cross a boundary, use the **same named type** on both
  sides. Do not rely on `@as` between two different named shapes in native
  builds.
- Avoid relying on width-subset or field-order compatibility in native builds
  until the native backend implements structural layout conversion.
- On the VM, function-typed fields work with top-level function pointers; avoid
  closure literals in fields if the code must run on both backends.
- Use `@struct` when the type needs methods or a stable nominal identity; use
  shapes for structural interfaces and ad-hoc records.

---

## 9. Choosing a Representation

| Need | Use |
| :--- | :--- |
| A named domain type with invariants and methods | `@struct` |
| A structural interface implemented by many record types | Anonymous shape (keep spelling exact for native) |
| A reusable named structural record | `@type Name = { ... };` (same name on both sides for native) |
| A transparent synonym for an existing shape | `@alias` |
| A generic record parameterized by a type | Type function returning a shape, or a generic `@struct` |
| A record with function-valued fields | Shape or struct; see §7 for backend differences |

---

## 10. See Also

- [User-Defined Types](user-defined.md) — `@struct`, `@enum`, `@error`,
  `@type`, and `@alias`.
- [Compound and Structural Types](compound-types.md) — arrays, slices, tuples,
  pointers, and anonymous shapes.
- [Functions & Methods](../functions.md) — receivers, generic structs, and type
  functions.
- [Type System Overview](README.md) — the nominal/structural split and type
  rules.