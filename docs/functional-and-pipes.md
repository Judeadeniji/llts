# Functional Programming & The Pipe Operator (`|>`)

LLTS combines systems-level stack memory with expressive functional idioms. Functions are first-class values with explicit static types, and the pipe operator (`|>`) allows data transformations to be expressed as clean, linear, left-to-right pipelines with zero runtime allocation overhead.

---

## 1. First-Class Functions

In LLTS, functions can be assigned to variables, passed into other functions, stored in structs, and invoked dynamically.

### 1.1 Function Type Signatures

Function types are specified using `@func(ParamTypes...): ReturnType`:

```llts
# A function taking two i64 parameters and returning an i64
$operation: @func(i64, i64): i64;

# A function taking no parameters and returning void
$callback: @func(): void;

# A predicate function taking a string and returning bool
$validator: @func(string): bool;
```

### 1.2 Function Values & Variables

Named functions can be referenced as values without parentheses:

```llts
@func add(a: i64, b: i64): i64 {
    return a + b;
}

@func multiply(a: i64, b: i64): i64 {
    return a * b;
}

pub @func main() {
    # Assigning a function to a variable
    $fn: @func(i64, i64): i64 = add;
    print(fn(3, 4)); # 7

    # Rebinding to another function with an identical signature
    fn = multiply;
    print(fn(3, 4)); # 12
}
```

### 1.3 Memory Layout of Function Values

In LLTS, a function value is a direct machine function pointer:
- Size: `@sizeOf(@func(i64): i64)` is exactly 8 bytes (one machine word on 64-bit systems).
- Overhead: Zero heap allocation, zero garbage collector tracing, and direct indirect-call dispatch.

### 1.4 Nominal Function Types (`@type`)

To improve readability and create domain abstractions, declare nominal function types with `@type`:

```llts
@type BinaryOp = @func(i64, i64): i64;
@type Predicate = @func(i64): bool;
@type Transformer = @func([]u8): []u8;

@func execute(a: i64, b: i64, op: BinaryOp): i64 {
    return op(a, b);
}
```

### 1.5 Storing Functions in Structs and Shapes

Function pointers integrate with nominal structs and anonymous shapes:

```llts
@type Command = {
    name: string;
    action: @func(): void;
};

@func ping() { print("pong"); }

pub @func main() {
    $cmd = Command { name: "ping", action: ping };
    cmd.action(); # prints "pong"
}
```

### 1.6 Closures: Anonymous Functions with Captures

An `@func(...)` expression is a closure literal. It can be assigned to a binding, returned from a function, stored in a struct, or called immediately:

```llts
pub @func main() {
    $factor: int = 4;
    $quad = @func(x: int): int {
        return x * factor;
    };
    print(quad(10)); # 40
    print(quad(25)); # 100
}
```

#### Capture Rules

- A closure captures the bindings and parameters of its enclosing function lexically. Captured values are copied into the closure's environment when the closure is created.
- A capture the closure assigns to is promoted to a **shared cell**. The enclosing binding and every closure capturing it read and write the same storage, so mutations are visible on both sides:

```llts
pub @func main() {
    $counter: int = 0;
    $inc = @func(): int {
        counter = counter + 1;
        return counter;
    };
    print(inc()); # 1
    print(inc()); # 2
    print(counter); # 2
}
```

#### Escape Classification

The compiler classifies each closure by how its value is used. This drives native lowering (see [§7.1](#71-native-backend-support-for-first-class-functions)):

| Kind | Condition | Native environment |
|---|---|---|
| **Non-escaping** | The closure value is only used for direct calls in the frame where it was created. | Stack local, seeded at the declaration. |
| **Escaping** | The closure is returned, stored in a struct/array or module-level binding, or passed to a function that may retain it. | Immortal heap cell, valid past the frame. |

```llts
# Escaping: the returned closure outlives makeAdder's frame.
@func makeAdder(base: int): @func(int): int {
    return @func(v: int): int {
        return base + v;
    };
}

pub @func main() {
    $add10 = makeAdder(10);
    print(add10(5));  # 15
    print(add10(20)); # 30
}
```

#### Immediate Invocation

A closure literal can be called in place, without a binding:

```llts
$res = (@func(x: int): int { return x * 3; })(14);
print(res); # 42
```

---

## 2. The Pipe Operator (`|>`)

The pipe operator (`|>`) is a syntactic mechanism for composing function calls. It takes the expression on its left-hand side and supplies it as the **first argument** to the callable on its right-hand side.

```text
lhs |> f(a, b)   ====>   f(lhs, a, b)
```

### 2.1 The Problem: Nested Call Inversion

In traditional nested function calls, execution order reads from inside-out, right-to-left:

```llts
# Hard to read: execution order is parse -> validate -> transform -> print
print(transform(validate(parse(raw_data))));
```

With the pipe operator, execution order mirrors the natural flow of data:

```llts
# Clear and sequential:
raw_data |> parse() |> validate() |> transform() |> print();
```

---

## 3. Pipe Syntax & Application Forms

The pipe operator supports several invocation shapes:

### 3.1 Bare Callee Form

When the right-hand side is a bare identifier or callable value, parentheses are optional:

```llts
@func double(n: i64): i64 { return n * 2; }

$result = 21 |> double; # Equivalent to: double(21)
print(result);          # 42
```

### 3.2 Trailing Argument Form

When the callee requires multiple arguments, the left-hand operand fills the **first parameter**, and arguments in parentheses fill the remaining parameters:

```llts
@func add(a: i64, b: i64): i64 {
    return a + b;
}

@func clamp(val: i64, min: i64, max: i64): i64 {
    @if (val < min) { return min; }
    @if (val > max) { return max; }
    return val;
}

pub @func main() {
    # 10 fills 'a', 5 fills 'b' -> add(10, 5)
    $sum = 10 |> add(5); 
    print(sum); # 15

    # 120 fills 'val', 0 fills 'min', 100 fills 'max' -> clamp(120, 0, 100)
    $bounded = 120 |> clamp(0, 100);
    print(bounded); # 100
}
```

### 3.3 Piping into Methods

The pipe operator works seamlessly with struct methods. The receiver object remains before the dot, and the left-hand operand is supplied as the method's first parameter:

```llts
@struct Counter {
    count: i64;

    @func add(self: Counter, delta: i64): Counter {
        return Counter { count: self.count + delta };
    }
}

pub @func main() {
    $c = Counter { count: 10 };

    # 5 is passed as the 'delta' parameter to c.add
    $updated = 5 |> c.add;
    print(updated.count); # 15
}
```

### 3.4 Piping into Imported Module Functions

Pipes work directly across module boundaries:

```llts
# --- file: math.lls ---
pub @func square(n: i64): i64 { return n * n; }

# --- file: main.lls ---
@const $math = @import("./math.lls");

pub @func main() {
    $value = 9 |> math.square;
    print(value); # 81
}
```

---

## 4. Evaluation Order & Precedence

The pipe operator is **left-associative** and operates at the additive precedence level (sharing precedence with `+` and `-`):

### 4.1 Chaining Flow
Chained pipes evaluate sequentially from left to right:

```llts
@func inc(x: i64): i64 { return x + 1; }
@func dbl(x: i64): i64 { return x * 2; }

pub @func main() {
    # (((5 |> dbl) |> inc) |> dbl)
    # 5 * 2 = 10 -> 10 + 1 = 11 -> 11 * 2 = 22
    $out = 5 |> dbl |> inc |> dbl;
    print(out); # 22
}
```

### 4.2 Precedence with Arithmetic Operators
Because `|>` shares precedence with addition and subtraction:
- Multiplicative expressions (`*`, `/`, `%`) bind tighter than `|>`:
  ```llts
  2 * 3 |> double # Evaluates as: double(2 * 3) -> double(6) -> 12
  ```
- Additive expressions (`+`, `-`) evaluate left-to-right with `|>`:
  ```llts
  1 + 2 |> double # Evaluates as: double(1 + 2) -> double(3) -> 6
  1 |> double + 1 # Evaluates as: (double(1)) + 1 -> 2 + 1 -> 3
  ```

### 4.3 Piped Expressions in Control Flow
Piped expressions can appear inside `@if` conditions and loop guards:

```llts
@func isEven(n: i64): bool { return n % 2 == 0; }

@if (8 |> isEven) {
    print("8 is even");
}
```

---

## 5. Higher-Order Functions & Collection Pipelines

Higher-order functions accept functions as arguments to transform sequences and aggregates.

### 5.1 Transform Pipeline Example

```llts
@func mapDouble(items: [4]i64): [4]i64 {
    $out: [4]i64 = [0, 0, 0, 0];
    @for (items) |val, idx| {
        out[idx] = val * 2;
    }
    return out;
}

@func sumArray(items: [4]i64): i64 {
    $total = 0;
    @for (items) |val| {
        total = total + val;
    }
    return total;
}

pub @func main() {
    $raw: [4]i64 = [1, 2, 3, 4];

    # Data flows through transformation functions
    $total = raw 
        |> mapDouble() 
        |> sumArray();

    print(total); # (2 + 4 + 6 + 8) = 20
}
```

### 5.2 Dynamic Higher-Order Dispatch

```llts
@func applyTwice(x: i64, transform: @func(i64): i64): i64 {
    return transform(transform(x));
}

@func addTen(n: i64): i64 { return n + 10; }

pub @func main() {
    $res = 5 |> applyTwice(addTen);
    print(res); # 5 + 10 + 10 = 25
}
```

---

## 6. Compile-Time Validation & Safety Invariants

The compiler typechecks pipe expressions statically:

### 6.1 Target Must Be Callable
Attempting to pipe into a non-callable value triggers a compile-time rejection:
```llts
$x = 5;
# COMPILE ERROR: Pipe target must be a function
10 |> x; 
```

### 6.2 Arity Matching
The compiler verifies that the piped argument plus any explicit trailing arguments match the function's parameter count:

```llts
@func add(a: i64, b: i64): i64 { return a + b; }

# COMPILE ERROR: Function 'add' expected 2 arguments, got 1
5 |> add;

# COMPILE ERROR: Function 'add' expected 2 arguments, got 3
5 |> add(1, 2);
```

### 6.3 Argument Type Compatibility
The type of the left-hand expression must match the function's first parameter:

```llts
@func printLength(s: string) { print(len(s)); }

# COMPILE ERROR: Incompatible type for argument 1 of 'printLength' (expected 'string', got 'i64')
100 |> printLength;
```

---

## 7. Backend Lowering & Zero-Cost Abstraction

The pipe operator introduces **zero runtime overhead**. It is purely a syntactic convenience:

- **Bytecode VM Pipeline:** The compiler compiles `a |> f(b)` directly into bytecode as if `f(a, b)` was written. No intermediate heap closures or trampoline functions are emitted.
- **Native Backend Pipeline:** The native emitter desugars `a |> f(b)` straight into direct Zig call instructions:
  ```zig
  // LLTS: 10 |> add(5)
  // Emitted Zig:
  try lls_fn_add(ctx, 10, 5);
  ```
  Method pipes (`4 |> c.add`) lower directly to method calls (`Counter::add(ctx, c, 4)`).

### 7.1 Native Backend Support for First-Class Functions

In the native backend (`emit-zig`), first-class function values are handled as follows:
- **Static Devirtualization:** When a function alias (e.g. `$pick = lib.mul`) or a function returning a function (`getAdder()(1, 2)`) is called, the compiler statically resolves the call target and emits a direct call to the mangled function (`lls_fn_...`).
- **Function Pointer Signatures:** Functions returning or taking `@func(...)` types lower to concrete Zig function pointer types (`*const fn(*rt.Context, ...) anyerror!Ret`).
- **Runtime Materialization Restriction:** Function values cannot be passed directly to generic runtime formatting positions like `print(...)`; attempting to do so is rejected at compile time with `cannot materialize function value at runtime`.
- **Closure Environments:** A closure's captures live in a generated `lls_env_<id>` struct. A closure that never escapes gets a stack local (`lls_env_stack_<id>`) seeded where the closure is created, so building it is a stack write with no heap allocation. A closure that escapes — returned, stored into an aggregate or a module-level binding, or handed to a function that may keep it — gets an immortal cell (`ctx.allocImmortal`) so its environment outlives the declaring frame.
- **Devirtualized Closure Calls:** When a closure is bound to a local declaration that is never read as a value or reassigned, and the closure does not escape, the compiler records the closure id at each direct call site and emits a direct call to the mangled closure function (`lls_closure_fn_<id>`), skipping the function-pointer indirection. Reading or reassigning the binding disables devirtualization for that closure (the indirect call goes through the fat pointer).
- **Bound Function Parameters:** A parameter of a higher-order function is bound to a closure when every recorded call site passes the same closure literal, the parameter does not escape, and it is never assigned or reassigned. Calls through that parameter then invoke the closure's mangled function directly. The closure may be passed as a literal or through a variable that is never reassigned and whose closure never escapes. Reassigned variables, or one instance reached through two different closures, leave the call indirect.
- **Struct Fields:** A call through a struct field devirtualizes when the object is a local built from a struct literal whose matching field holds the same closure literal. The object must never be assigned afterwards — a field write, taking its address, or a pointer-receiver call all disable it — and each object keeps its own field facts, so two locals holding different closures both call directly. The environment is still read from the field, so only the indirection disappears.
- **Array Elements:** A call through `handlers[0]` devirtualizes when the array is a local built from an array literal at a compile-time constant index and that element holds the closure literal (or a never-reassigned local bound to one). The array must never be assigned afterwards — an element write, taking its address, or passing it by pointer all disable it.
- **What Stays Indirect:** A call keeps the function-pointer indirection whenever its target is not one fixed closure literal visible in the same function: elements reached through a runtime index (`handlers[i]`), closures produced by a call or received as a parameter, aggregates that are assigned or have their address taken, and closures held in a nested aggregate (`outer.inner.f()`) — a fact names one local aggregate, not a path through it. LLTS has no map literals, so only struct fields and array elements are candidates.
- **Immediate Invocation:** A closure literal in call position — `(@func(x: int): int { … })(14)` — is supported. The native emitter seeds its stack environment at the call site, immediately before the call.
