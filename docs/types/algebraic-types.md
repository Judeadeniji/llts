# Algebraic Types & Flow Narrowing

LLTS provides algebraic type constructors — optionals, unions, and intersections — combined with compile-time flow typing and narrowing.

---

## 1. Optional Types (`?T`)

An optional type represents a value that may either be of type `T` or `null`. Syntactically, `?T` is shorthand for the union `T | null`.

```lls
$score: ?i64 = 100;
$empty_score: ?i64 = null;
```

### Unwrapping Optionals

LLTS provides four mechanisms to safely work with and unwrap optionals:

#### 1. Assertion Unwrap (`.?`)
The `.?` postfix operator unwraps the payload if present, or panics at runtime if the value is `null`:

```lls
$val: ?i64 = 42;
$unwrapped: i64 = val.?; # 42

$missing: ?i64 = null;
# $crashed = missing.?;   # Panics / traps: attempted to unwrap null
```

#### 2. Null-Coalescing Operator (`??`)
The `??` binary operator provides a fallback value if the left operand is `null`:

```lls
$input: ?string = null;
$username = input ?? "guest"; # Evaluates to "guest"
```

#### 3. Capture-Unwrapping in `@if`
The `@if (val) |unwrapped|` syntax safely extracts the payload within the then-branch:

```lls
$maybe_user: ?string = "Alice";

@if (maybe_user) |name| {
    print("Welcome, ", name); # 'name' has type string
} @else {
    print("Welcome, guest");
}
```

#### 4. Flow-Sensitive Null Checks (`!= null`)
In strict mode (`--strict`), comparing an optional against `null` automatically narrows the variable within that branch:

```lls
@struct Config { port: i64; }

pub @func main() {
    $cfg: ?Config = Config { port: 8080 };

    @if (cfg != null) {
        # 'cfg' is automatically narrowed to Config within this block
        print(cfg.port); # Direct field access is safe and checked
    }
}
```

---

## 2. Union Types (`A | B`)

A union type represents a value that can be any one of the specified types. Unions are commutative and flattened automatically: `A | B | C`.

```lls
$id: i64 | string = 101;
id = "usr_101"; # Valid
```

### Error Unions
The most common union pattern in LLTS is returning a result or a typed error:

```lls
@error ParseError { Invalid, Empty }

@func parse_int(s: string): i64 | ParseError {
    @if (s == "") {
        return ParseError.Empty;
    }
    return 42;
}
```

### Propagating Error Unions (`?`)
The postfix `?` try operator unwraps an error union. If the expression evaluates to an error, the error is immediately returned from the enclosing function:

```lls
@func load_data(): i64 | ParseError {
    $count = parse_int("123")?; # Unwrapped to i64, or early-returns ParseError
    return count * 2;
}
```

---

## 3. Flow-Sensitive Type Narrowing

The LLTS typechecker tracks control flow and narrows union and optional types:

### Narrowing via Equality
```lls
$val: ?string = "data";

@if (val == null) {
    return;
}
# Past the early-exit check, 'val' is soundly narrowed to 'string'
print(val);
```

### Narrowing via `@switch`
`@switch` expressions inspect and narrow unions and error variants:

```lls
@error HttpError { NotFound, Timeout }

@func handle(res: i64 | HttpError) {
    @switch (res) {
        HttpError.NotFound => {
            print("Resource not found");
        },
        HttpError.Timeout => {
            print("Request timed out");
        },
        @else => {
            # In the fallback branch, res is narrowed to i64
            print("Status code:", res);
        },
    };
}
```

---

## 4. Intersection Types (`A & B`)

The `&` type operator creates an intersection type. In LLTS, intersection is supported for two distinct categories:

### 1. Shape Intersections
When applied to structural shapes, `&` merges the fields of both types into a single composite type:

```lls
@type HasId = { id: i64; };
@type HasTimestamp = { created_at: i64; };

# Combined type has both 'id: i64' and 'created_at: i64'
@type Record = HasId & HasTimestamp;
```
- If both shapes declare a field with the same name, the field types must be strictly identical; conflicting field types cause a compile-time error.

### 2. Error Set Intersections
When applied to closed `@error` sets, `&` forms an error set that can hold variants from either error set (a closed union of errors):

```lls
@error FileError { ReadFail, WriteFail }
@error NetError { ConnectionReset, Timeout }

# AppError accepts all variants from FileError and NetError
@type AppError = FileError & NetError;
```

---

## 5. Literal Types & `const` Assertions

LLTS supports singleton literal types for strings, integers, and booleans.

### Singleton Literals
A literal type contains only that exact value:
- `"admin"` is a subtype of `string`.
- `404` is a subtype of `i64`.
- `true` is a subtype of `bool`.

### The `const` Expression Assertion
By default, literals in mutable variables are widened to their base types (`"hello"` becomes `string`). Use the prefix `const` operator to preserve singleton literal types:

```lls
# 'a' is typed as 'string' (const []u8)
$a = "hello";

# 'b' has the exact singleton type '"hello"'
$b = const "hello";

# Immutable @const bindings infer literal types automatically
@const $status = "success"; # Inferred type: '"success"'
```

Literal types allow expressive type-safe status tags:

```lls
@type Response = { status: "ok"; data: i64; } | { status: "error"; message: string; };
```

---

## 6. Forbidden Union Arms

LLTS enforces a strict soundness rule regarding non-value types:

> **Soundness Invariant:** Neither `void` nor `never` may appear as an arm of a union or optional.

- `?void` $\to$ **Compile Error:** `void` cannot appear in a union or optional; it is not a value-carrying type.
- `i64 | void` $\to$ **Compile Error:** Use `?i64` (`i64 | null`) instead.
- `string | never` $\to$ **Compile Error:** `never` represents unreachable control flow, not a runtime value.
