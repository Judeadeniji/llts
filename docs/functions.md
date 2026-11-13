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
- **Backend Lowering:** The bytecode VM packs variadic arguments into dynamic arrays. The native backend (`--native` / `emit-zig`) lowers rest parameters to Zig slice views (`[]const T`), packing trailing call-site arguments into zero-overhead stack arrays (`&[_]T{ ... }`).

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

### Method Type Parameters

A method may take `type` parameters (and compile-time integer parameters)
of its own, on a plain struct as well as on a generic instance. The receiver
is still the implicit first argument and never counts among the arguments you
pass:

```lls
@struct Pair(A: type, B: type) { first: A; second: B; }

@struct Point {
    x: i64;
    y: i64;

    @func as(self, T: type): T { return @as(T, self.x); }
    @func pairWith(self, T: type, v: T): Pair(i64, T) { return { first: self.x, second: v }; }
}

pub @func main() {
    $p: Point = { x: 3, y: 4 };
    print(p.as(f64));                # 3
    $q = p.pairWith(bool, true);     # explicit type argument
    print(q.first, q.second);        # 3 true
    $r = p.pairWith(false);          # inferred from the value argument
    print(r.first, r.second);        # 3 false
}
```

Each distinct argument list instantiates the method once, so `p.as(f64)` and
`p.as(i64)` are different functions with different return types. Explicit type
arguments lead the argument list and bind no value parameter; when they are
omitted they are inferred from the value arguments. A method's return type may
name a generic instance (`Pair(i64, T)`) or an anonymous shape
(`{ value: i64; extra: T }`), and a call to one already has that type — so
`$q = p.pairWith(bool, true)` needs no annotation.

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

### Anonymous Functions (Closures)

An `@func(...)` expression is an anonymous function that may capture bindings from the scope where it is written. Captures are taken by value; a capture the closure mutates is promoted to a shared cell so writes are visible in the enclosing function. Closures whose values never leave the declaring frame are stack-allocated in the native backend, while escaping closures (returned or stored) get immortal environments. See [Closures & Capture](functional-and-pipes.md#16-closures-anonymous-functions-with-captures) for the full rules.

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

---

## 9. Generic Struct Declarations

A struct may take type parameters. The declaration itself is a template: it is
never laid out or emitted. Every distinct argument list instantiates its own
struct, with the parameters substituted in the fields and in the methods:

```lls
@struct Pair(A: type, B: type) {
    first: A;
    second: B;

    @func swap(self): Pair(B, A) {
        return Pair(B, A) { first: self.second, second: self.first };
    }
}

pub @func main() {
    # `Pair(i64, bool)` and `Pair(bool, i64)` are distinct structs.
    $p: Pair(i64, bool) = { first: 1, second: true };
    $q = p.swap();
    print(q.first, q.second); # true 1
}
```

- `Name(T)` is a type, so it works anywhere a type does: annotations,
  parameters, returns, struct fields, `@alias`, `@sizeOf`, `@new`.
- `Name(T) { … }` is the object literal form; an annotated `$x: Name(T) = { … }`
  is equivalent.
- Instances nest (`Name(Other(T))` instantiates the inner type first) and may
  refer to themselves through a pointer (`next: ?*Name(T)`).
- Methods of an instance are ordinary methods of that instance
  (`Name(T)::method`); a method may still take type parameters of its own.
- Integer value parameters size array fields: `@struct Buffer(T: type, N: i64)
  { items: [N]T; }`. The value substitutes into array lengths only (never into
  a field's runtime value), is part of the instance key, and must be a
  compile-time integer, so `Buffer(u8, 4)` and `Buffer(u8, 8)` are distinct
  types. `@enum` declarations cannot take parameters — variants carry no types.
- An instance is only a type until something uses it: its methods are checked
  on first use, so a method that does not hold for every element type
  (`sum` over `Buffer(bool, 4)`) cannot break an unrelated `@sizeOf` use.

## 10. Returning Object Literals

A function with a declared return type accepts a bare object literal that
matches it, so `Point { … }` need not be repeated:

```lls
@struct Point { x: i64; y: i64; }

@func origin(): Point {
    return { x: 0, y: 0 };
}
```

The literal is checked field-by-field against the declared type, and the
result has that type (so `origin().x` and `@sizeOf(Point)` behave as expected).
This also works for anonymous shape returns and generic instances:

```lls
@func pair(): { a: i64; b: bool } { return { a: 1, b: true }; }

@func wrap(T: type, v: T): Box(T) { return { v: v }; }
```
