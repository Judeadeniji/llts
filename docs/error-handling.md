# Error Handling in LLTS

LLTS rejects untyped hidden exceptions in favor of **explicit, typed error values**. Errors are treated as first-class return values using error unions (`T | ErrorSet`), unwrap operators (`?`), pattern matching (`@switch`), and dedicated cleanup hooks (`errdefer`).

---

## 1. Closed Typed Error Sets (`@error`)

Typed error sets declare nominal, closed collections of error variants:

```lls
@error FileError {
    NotFound,
    PermissionDenied,
    DiskFull,
}
```

### Accessing Variants
Error variants are referenced with dot notation (`ErrorSetName.Variant`):

```lls
$err = FileError.NotFound;
```

### Combining Error Sets with `&`
Multiple error sets can be combined into a single unified error set using the intersection operator `&`:

```lls
@error NetError {
    Timeout,
    ConnectionRefused,
}

# AppError accepts any variant from FileError or NetError
@type AppError = FileError & NetError;
```

---

## 2. Dynamic Errors (`error("...")`)

For simpler scripts or dynamic failure messages, LLTS provides dynamic errors constructed with `error("message")`:

```lls
@func validate_age(age: i64): bool | error {
    @if (age < 0) {
        return error("Age cannot be negative");
    }
    return true;
}
```

- Dynamic errors carry the built-in type `error`.
- Two dynamic errors compare equal if their messages match.

---

## 3. Error Union Types

Functions that can fail declare their return type as an error union combining the success payload and the error type:

```lls
@error MathError {
    DivideByZero,
}

@func divide(a: f64, b: f64): f64 | MathError {
    @if (b == 0.0) {
        return MathError.DivideByZero;
    }
    return a / b;
}
```

In strict mode (`--strict`), returning an error without declaring it in the return type is rejected at compile time.

---

## 4. Error Propagation with `?` (Try Operator)

The postfix `?` operator unwraps the success payload of an error union. If the expression evaluates to an error, it is **immediately returned** from the enclosing function:

```lls
@func compute_ratio(a: f64, b: f64): f64 | MathError {
    # If divide returns MathError.DivideByZero, compute_ratio returns it immediately
    $ratio = divide(a, b)?;

    # 'ratio' is unwrapped to a clean f64
    return ratio * 100.0;
}
```

### Comparison: `?` vs `.?`

| Operator | Target | Behavior on Success | Behavior on Failure |
| :---: | :--- | :--- | :--- |
| **`?`** | Error Union (`T \| Error`) | Unwraps payload (`T`) | Early-returns the error to caller |
| **`.?`** | Optional Type (`?T` / `T \| null`) | Unwraps payload (`T`) | **Panics/traps** at runtime on `null` |

---

## 5. Inspecting Errors with `@isError`

The `@isError(expression)` compiler intrinsic checks at runtime whether a value is an error (either a typed `@error` variant or a dynamic `error("...")`):

```lls
pub @func main() {
    $res = divide(10.0, 0.0);

    @if (@isError(res)) {
        print("Calculation failed with error:", res);
    } @else {
        print("Result:", res);
    }
}
```

- Returns `true` for any error value.
- Returns `false` for normal values, including `null`, `false`, `0`, and empty strings.

---

## 6. Pattern Matching on Error Sets (`@switch`)

`@switch` provides exhaustive pattern matching over error sets:

```lls
@error DbError {
    RecordNotFound,
    ConnectionLost,
    DuplicateKey,
}

@func handle_db(e: DbError) {
    @switch (e) {
        DbError.RecordNotFound => {
            print("Creating default record...");
        },
        DbError.ConnectionLost => {
            print("Retrying connection...");
        },
        DbError.DuplicateKey => {
            print("Record already exists");
        },
    }
}
```

### Compiler Exhaustiveness Checking
The compiler verifies that all members of an `@error` set are handled. If any member is omitted and no `@else` fallback is provided, compilation fails with a `missing error member` error.

---

## 7. Resource Cleanup with `errdefer`

LLTS provides `errdefer` to ensure resource cleanup runs **only** when exiting a scope due to an error return:

```lls
@func perform_transaction(): void | DbError {
    start_transaction();
    errdefer rollback_transaction(); # Runs ONLY if an error is returned
    defer log_transaction_attempt();  # Runs ALWAYS on scope exit

    validate_inputs()?;  # If this fails, rollback runs
    write_database()?;   # If this fails, rollback runs

    commit_transaction();
    return;              # On success, rollback is NOT executed
}
```

### `defer` vs `errdefer` Execution Order:
- `defer` and `errdefer` execute in **Last-In, First-Out (LIFO)** order.
- On a successful exit (`return value;` or end of scope), only `defer` statements run.
- On an error exit (`return error;` or early-return via `?`), both `errdefer` and `defer` statements run in reverse declaration order.
