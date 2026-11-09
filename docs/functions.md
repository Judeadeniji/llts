# Functions and Methods in LLTS

Functions are fundamental building blocks in LLTS. LLTS supports top-level functions, struct methods with explicit receiver semantics, variadic arguments, first-class functions, pipe expressions, and compile-time type functions.

---

## 1. Function Declarations

Functions are declared using the `@func` keyword:

```lls
@func add(a: i64, b: i64): i64 {
    return a + b;
}
```

- **Parameters:** Written as `name: Type`. In strict mode (`--strict`), parameter type annotations are mandatory.
- **Return Type:** Appended after the parameter list with `: ReturnType`. If omitted or if the function returns no value, the return type defaults to `void`.
- **Return Statement:** Explicit `return <value>;` is required for functions with non-void return types. Bare `return;` exits a `void` function early.

---

## 2. Program Entry Point (`main`)

Every standalone executable defines an exported `main` function:

```lls
pub @func main() {
    print("Program started");
}
```

- Must be marked with `pub` to be visible to the runtime linker.
- Returns `void` by default.

---

## 3. Parameter Conventions & Variadics

### Standard Parameters
Parameters are passed by value for scalar types (`i64`, `f64`, `bool`). Aggregates passed directly by value are copied into the function's stack frame; to avoid copying or to mutate caller state, pass a pointer (`*T`):

```lls
@struct Config { port: i64; }

@func update_port(cfg: *Config, new_port: i64) {
    cfg.port = new_port;
}
```

### Variadic / Rest Parameters (`...args`)
Functions can accept a variable number of trailing arguments using rest syntax:

```lls
# Rest-only parameter: packs all arguments into an array slice
@func sum(...args): i64 {
    $total = 0;
    @for (args) |val| {
        total = total + val;
    }
    return total;
}

# Named parameters followed by rest parameter
@func format_log(level: string, ...messages) {
    print("[", level, "]", messages[0]);
}

pub @func main() {
    print(sum(10, 20, 30)); # 60
    format_log("INFO", "Server listening", "port 8080");
}
```

- The rest parameter must always appear as the final parameter.
- At runtime, `args` behaves as a slice view whose element count can be inspected with `len(args)`.

---

## 4. Visibility & Module Exports (`pub`)

By default, functions are private to the file in which they are declared. Prepending `pub` exports the function, making it accessible to any module that imports the file:

```lls
# math_utils.lls
pub @func multiply(a: i64, b: i64): i64 {
    return a * b;
}

# Internal helper — not exported
@func internal_clamp(v: i64): i64 {
    return v;
}
```

---

## 5. Struct Methods & Receiver Semantics

Methods are functions declared directly inside a `@struct` body. The first parameter is always the receiver (`self`):

```lls
@struct Counter {
    value: i64;

    # 1. Unannotated 'self' defaults to pointer receiver (*Counter)
    @func increment(self) {
        self.value = self.value + 1;
    }

    # 2. Explicit pointer receiver (*Counter) for in-place mutation
    @func reset(self: *Counter) {
        self.value = 0;
    }

    # 3. Explicit value receiver (Counter) for read-only / copy semantics
    @func get_value(self: Counter): i64 {
        return self.value;
    }
}
```

### Receiver Rules:
1. **Unannotated `self`:** Defaults to a pointer receiver (`*T`). The compiler automatically borrows the address (`&`) of a value instance when calling the method.
2. **Explicit `self: *T`:** Direct pointer receiver; mutations affect the caller's struct in-place.
3. **Explicit `self: T`:** Value receiver; the struct is copied onto the callee's frame, leaving the caller's original struct untouched.
4. **Invocation:** Both value and pointer instances use identical dot syntax: `c.increment()`.

---

## 6. First-Class Functions

Functions can be passed as arguments, returned from other functions, and stored in variables.

### Function Types
A function type is written using `@func(ParamTypes): ReturnType`:

```lls
@alias BinaryOp = @func(i64, i64): i64;

@func add(x: i64, y: i64): i64 { return x + y; }
@func sub(x: i64, y: i64): i64 { return x - y; }

@func compute(a: i64, b: i64, op: BinaryOp): i64 {
    return op(a, b);
}

pub @func main() {
    print(compute(10, 5, add)); # 15
    print(compute(10, 5, sub)); # 5
}
```

> **Backend Note:** First-class function values and function pointers are fully supported on the Bytecode VM backend.

---

## 7. The Pipe Operator (`|>`)

The pipe operator (`|>`) passes the left-hand expression as the **first argument** of the right-hand call:

```lls
@func double(n: i64): i64 { return n * 2; }
@func add_one(n: i64): i64 { return n + 1; }

pub @func main() {
    # 5 |> double() becomes double(5) -> 10
    # 10 |> add_one() becomes add_one(10) -> 11
    $val = 5 |> double() |> add_one();
    print(val); # 11
}
```

### Passing Additional Arguments:
When the target function takes multiple arguments, the piped value becomes argument 1, and the parenthesized arguments follow:

```lls
@func clamp(val: i64, min_val: i64, max_val: i64): i64 {
    @if (val < min_val) { return min_val; }
    @if (val > max_val) { return max_val; }
    return val;
}

pub @func main() {
    # Equivalent to clamp(120, 0, 100)
    $bounded = 120 |> clamp(0, 100);
    print(bounded); # 100
}
```

---

## 8. Type Functions (Compile-Time Generics)

Rather than introducing an elaborate template or macro syntax, LLTS supports generics through **type functions** — ordinary functions that take and return values of type `type`:

```lls
# Type function that constructs an optional wrapper shape
@func OptionalBox(T: type): type {
    return {
        value: ?T;
        has_value: bool;
    };
}

pub @func main() {
    # Instantiate the generic shape
    @type IntBox = OptionalBox(i64);

    $box: IntBox = IntBox {
        value: 42,
        has_value: true,
    };
    print(box.has_value);
}
```

- Executed strictly at compile time.
- Returns concrete structural shapes, tuples, or union types.
