# Type Soundness, Flow Analysis & Discriminated Unions

LLTS features an advanced compile-time flow analysis engine (`src/compiler/typecheck/flow.zig`). In strict mode (`--strict`, enabled by default for `--native`), the typechecker enforces mathematical type soundness: eliminating null pointer exceptions, unhandled union states, and implicit type coercions at compile time.

---

## 1. The LLTS Soundness Model

LLTS balances rapid prototyping with systems-level safety through two operating modes:

| Dimension | Default Mode (VM) | Strict Mode (`--strict` & Native) |
|---|---|---|
| **Parameter Annotations** | Optional (defaults to `unknown`) | Mandatory on all `@func` declarations |
| **Truthiness Coercion** | Permissive (numbers/strings/pointers in `@if`) | Strictly prohibited (condition must be `bool`) |
| **Null Access** | Runtime checks / traps | Static compile-time rejection |
| **Union Access** | Partial fields permitted | Static compile-time rejection without narrowing |
| **Exhaustive Matching** | Warns on missing `@switch` arms | Hard compile-time error |

---

## 2. Strict Mode Invariants

When `--strict` is enabled (or when compiling natively via `llts run --native` or `llts build --native`), the compiler activates three non-negotiable invariants:

### 2.1 Mandatory Function Parameter Annotations
Functions cannot leave parameter types implicit:

```llts
# COMPILE ERROR in strict mode:
# Parameter 'n' of function 'double' must have an explicit type annotation
@func double(n) { return n * 2; }

# Valid:
@func double(n: i64): i64 { return n * 2; }
```

### 2.2 Rejection of Truthiness Coercion
In dynamic languages like JavaScript or Python, arbitrary values are coerced to booleans in conditionals. In LLTS strict mode, the condition of an `@if` statement must evaluate to a boolean (`bool` / `u1`):

```llts
$count = 5;

# COMPILE ERROR in strict mode: Condition of @if must be boolean
@if (count) { print("has count"); }

# Valid: explicit comparison
@if (count > 0) { print("has count"); }
```

For optional values (`?T`), truthiness coercion is replaced by explicit comparison (`opt != null`) or the safe payload capture form (`@if (opt) |val|`).

### 2.3 Strict Null Dereference Protection
Accessing fields or indices on an optional type without narrowing or unwrapping is statically forbidden:

```llts
@struct User { name: string; }

$u: ?User = User { name: "Alice" };

# COMPILE ERROR: Cannot access field 'name' on optional type '?User'
print(u.name); 
```

---

## 3. Flow-Sensitive Type Narrowing

Flow analysis tracks the type of variables along each branch of execution. When a condition proves that a variable cannot hold certain values, the compiler narrows its type within that lexical scope.

### 3.1 Null Checking: `@if (x != null)` and `@if (x == null)`

Comparing an optional variable against `null` refines its type in the corresponding branch:

```llts
@struct User { name: string; }

pub @func main() {
    $u: ?User = User { name: "Alice" };

    @if (u != null) {
        # 'u' is narrowed from '?User' to 'User'
        print(u.name); # OK: direct field access allowed
    } @else {
        # 'u' is narrowed to 'null'
        # print(u.name); # COMPILE ERROR: Cannot access field on type 'null'
    }
}
```

Similarly, checking for equality with `null` narrows the `else` branch:

```llts
@if (u == null) {
    print("No user");
} @else {
    print(u.name); # OK: 'u' is narrowed to 'User' here
}
```

### 3.2 Optional Payload Capture: `@if (x) |val|`

The capture syntax unwraps an optional value safely into a block variable. In LLTS, this narrows **both** the capture variable and the original variable:

```llts
$u: ?User = User { name: "Bob" };

@if (u) |user| {
    print(user.name); # OK: capture 'user' is 'User'
    print(u.name);    # OK: original variable 'u' is also narrowed to 'User'
}
```

### 3.3 Assignment-Driven Narrowing

Assigning a concrete value to an optional variable refines its type immediately:

```llts
$u: ?User = null;

# Assignment narrows 'u' from '?User' to 'User'
u = User { name: "Charlie" };
print(u.name); # OK: statically known as 'User'
```

If the variable is later assigned `null`, the compiler re-widens it back to `?User`:

```llts
u = null;
# print(u.name); # COMPILE ERROR: Cannot access field 'name' on type 'null'
```

---

## 4. Control-Flow Branch Joins

When divergent control-flow paths merge, the type of a variable at the join point is the **union of its types across all incoming paths**.

### 4.1 The Asymmetric Branch Join (Re-Widening)
If an `@if` block narrows a variable but the path rejoins without an `@else` or an early exit, the variable reverts to its wider un-narrowed type:

```llts
$u: ?User = User { name: "Dave" };

@if (u != null) {
    print("Found user:", u.name); # OK: narrowed to 'User'
}

# JOIN POINT: the condition might have been false!
# 'u' reverts to '?User'
# print(u.name); # COMPILE ERROR: Cannot access field 'name' on optional type '?User'
```

### 4.2 Early Exit (Guard Pattern)
To maintain the narrowed type for the remainder of the function, terminate the null branch with an early `return` or `break`:

```llts
pub @func processUser(u: ?User) {
    @if (u == null) {
        return; # Non-returning branch eliminates 'null' from subsequent flow
    }

    # Flow reaches here ONLY if u != null
    # 'u' is permanently narrowed to 'User'
    print(u.name); # OK!
}
```

### 4.3 Symmetric Branch Joins
If all branches ensure a concrete type, the narrowed type persists after the merge:

```llts
$u: ?User = null;

@if (some_condition) {
    u = User { name: "Path A" };
} @else {
    u = User { name: "Path B" };
}

# Both paths assigned 'User' -> Type at join is User | User == User
print(u.name); # OK!
```

---

## 5. Union Types (`A | B`) & Partial Access Rules

A union type `A | B` represents a value that can be either an `A` or a `B`.

### 5.1 The Partial Access Invariant
A field can be accessed on a union **only if that field is declared on every single member of the union**:

```llts
@struct Dog { name: string; bark_volume: i64; }
@struct Cat { name: string; lives_left: i64; }

@func speak(pet: Dog | Cat) {
    # 1. Shared field: declared on both Dog and Cat
    print(pet.name); # OK: 'name' is present on all arms

    # 2. Partial field: only declared on Dog
    # COMPILE ERROR: Field 'bark_volume' is not available on union type 'Dog | Cat'
    # print(pet.bark_volume);
}
```

To access fields unique to a specific struct, you must narrow the union.

---

## 6. Discriminated Unions with Kind Narrowing

A **discriminated union** (or tagged union) pairs a union of structs with a shared discriminator field (often named `kind` or `type`). 

LLTS implements zero-overhead discriminated unions by combining nominal enums with singleton field types:

### 6.1 Defining a Discriminated Union

```llts
@enum ShapeKind {
    Circle,
    Rectangle,
}

@struct Circle {
    kind: ShapeKind.Circle; # Singleton enum field
    radius: f64;
}

@struct Rectangle {
    kind: ShapeKind.Rectangle; # Singleton enum field
    width: f64;
    height: f64;
}

@type Shape = Circle | Rectangle;
```

### 6.2 Narrowing via `@switch (e.kind)`

When switching on the shared `kind` field, the compiler narrows the target variable within each match prong:

```llts
@func area(s: Shape): f64 {
    return @switch (s.kind) {
        # In this arm, 's' is statically narrowed to 'Circle'
        ShapeKind.Circle => {
            break 3.14159 * s.radius * s.radius;
        },

        # In this arm, 's' is statically narrowed to 'Rectangle'
        ShapeKind.Rectangle => {
            break s.width * s.height;
        },
    };
}
```

### 6.3 Exhaustiveness Enforcement
In strict mode, `@switch` expressions over discriminated unions must be exhaustive. If any variant is omitted and there is no `@else` fallback, compilation fails:

```llts
# COMPILE ERROR: Switch on enum 'ShapeKind' must be exhaustive; missing variant 'Rectangle'
@func badArea(s: Shape): f64 {
    return @switch (s.kind) {
        ShapeKind.Circle => { break 3.14159 * s.radius * s.radius; },
    };
}
```

---

## 7. Literal Singleton Types (`const <lit>`)

LLTS allows literals to serve as distinct types using the `const` prefix:

```llts
$status: const "ok" = "ok";
# $status = "error"; # COMPILE ERROR: Type '"error"' is not assignable to type '"ok"'
```

### 7.1 Modeling Zero-Overhead Protocol States
Literal types allow creating state machines and protocol responses with compile-time tag verification:

```llts
@type HttpResponse = 
    | { status: const 200; body: string; }
    | { status: const 404; error: string; }
    | { status: const 500; trace: string; };

@func handle(res: HttpResponse) {
    @switch (res.status) {
        200 => { print("Success:", res.body); },
        404 => { print("Not Found:", res.error); },
        500 => { print("Server Error:", res.trace); },
    };
}
```

Within each `@switch` arm, `res` is narrowed to the corresponding shape, unlocking `res.body`, `res.error`, or `res.trace` safely without runtime type tags.

---

## 8. Error Unions (`T ! E`) vs Optionals (`?T`)

LLTS treats fallible operations as error unions:

| Feature | Optional (`?T`) | Error Union (`T ! E` or `T \| E`) |
|---|---|---|
| **Underlying Type** | `T \| null` | `T \| ErrorSet` |
| **Absence Meaning** | Value does not exist / uninitialized | Operation failed with a typed diagnostic error |
| **Unwrap Assertion** | `.?` (panics on null) | None (use `?` to propagate or match) |
| **Propagation** | Manual check | `?` operator (returns error up the call stack) |
| **Runtime Query** | `val == null` | `@isError(val)` |
| **Narrowing Method** | `@if (x != null)` or `@if (x) \|v\|` | `@if (@isError(x)) { ... } @else { ... }` or `@switch` |

### Flow Narrowing with `@isError`

```llts
@error DatabaseError { ConnectionLost, Timeout }

@func query(): string ! DatabaseError {
    return "result_data";
}

pub @func main() {
    $res = query();

    @if (@isError(res)) {
        # 'res' is narrowed to DatabaseError
        print("Query failed");
    } @else {
        # 'res' is narrowed to 'string'
        print("Received:", res);
    }
}
```
