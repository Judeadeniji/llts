# Metaprogramming & Compile-Time Evaluation

LLTS provides compile-time metaprogramming and reflection without macros or separate template mini-languages. In LLTS, **types are first-class values** of type `type` at compile time, and the compiler includes an integrated constant-evaluation engine (`@comptime`).

---

## 1. Type Introspection

LLTS provides built-in compile-time intrinsics to inspect types, sizes, and declarations:

### `@typeOf(expression)`
Returns the concrete `type` value of an expression. `@typeOf` can be used wherever a type annotation is accepted:

```lls
$x: i64 = 42;

# 1. In local type annotations
$y: @typeOf(x) = 100;

# 2. In composite type constructors
$opt: ?@typeOf(x) = null;         # ?i64
$list: []@typeOf(x) = [1, 2, 3];   # []i64
$union_val: @typeOf(x) | f64 = 1.5;# i64 | f64

# 3. In function parameter and return annotations
@func add_same(a: i64, b: @typeOf(a)): @typeOf(a) {
    return a + b;
}
```

### `@sizeOf(Type)`
Returns the exact memory size in bytes of a type or variable:

```lls
print(@sizeOf(i64));     # 8
print(@sizeOf(u8));      # 1
print(@sizeOf(f32));     # 4
print(@sizeOf(bool));    # 1
print(@sizeOf(string));  # 16 (16-byte slice view: ptr + len)

@struct Vec3 { x: f64; y: f64; z: f64; }
print(@sizeOf(Vec3));    # 24
```

### `@nameOf(declaration_or_variant)`
Returns the string representation of an enum variant, error member, or named symbol:

```lls
@enum Color { Red, Green, Blue }
@error IoError { NotFound, Denied }

pub @func main() {
    print(@nameOf(Color.Red));        # "Red"
    print(@nameOf(IoError.NotFound)); # "NotFound"
}
```

- Works with enum variants, error members, and declared functions/variables.
- Rejects raw values and bare arithmetic expressions.

---

## 2. Explicit Type Conversions with `@as`

The `@as(TargetType, expression)` intrinsic performs explicit type casts:

```lls
$small: u8 = 10;
$wide: i64 = @as(i64, small);     # Numeric widening
$narrow: u8 = @as(u8, wide);      # Range-checked narrowing

@type UserId = i64;
$uid = @as(UserId, 1001);         # Cast to distinct nominal type
```

---

## 3. Type Functions (Compile-Time Generics)

Instead of complex generic syntax, LLTS supports generics through **type functions** — functions that accept parameters of type `type` and return a `type`:

```lls
# Constructs an optional type
@func Opt(T: type): type {
    return ?T;
}

# Type conditional: chooses wider type for u8
@func Widen(T: type): type {
    @if (T == u8) {
        return u16;
    }
    return T;
}

# Constructs generic structural record
@func Pair(T: type, U: type): type {
    return [T, U];
}

pub @func main() {
    $x: Opt(i64) = 42;
    $p: Pair(string, i64) = ["score", 95];

    print(@typeOf(x)); # ?i64
    print(p.0, p.1);   # score 95
}
```

### Key Properties:
- Type functions execute strictly at compile time.
- Can be nested: `Opt(Opt(i64))`.
- Can be bound to aliases: `@alias NullableInt = Opt(i64);`.

---

## 4. Generic Functions (Monomorphization)

Functions can accept type arguments alongside regular parameters. The compiler automatically monomorphizes the function for each distinct type combination:

```lls
@func max(T: type, a: T, b: T): T {
    @if (a > b) {
        return a;
    }
    return b;
}

pub @func main() {
    # Instantiated for i64
    $big_int = max(i64, 10, 42);
    print(big_int); # 42

    # Instantiated for f64
    $big_float = max(f64, 3.14, 2.71);
    print(big_float); # 3.14
}
```

Inside the function body:
- `T` is a compile-time constant representing the caller's type argument.
- Local variables and expressions can be annotated with `T`: `$local: T = a;`.

---

## 5. Constant Evaluation with `@comptime`

The `@comptime` keyword forces an expression or block to evaluate during compilation. The result is baked directly into the emitted binary or bytecode table as a constant value with zero runtime calculation cost.

### Precomputed Lookup Tables
```lls
@const $SQUARES = @comptime {
    $table = [0, 0, 0, 0, 0];
    @for (0..5) |i| {
        table[i] = i * i;
    }
    break table;
};

pub @func main() {
    print(SQUARES[0]); # 0
    print(SQUARES[3]); # 9
    print(SQUARES[4]); # 16
}
```

### Pure Function Folding
Calling a pure function inside `@comptime` evaluates the call at compile time:

```lls
@func factorial(n: i64): i64 {
    $result = 1;
    @for (1..n + 1) |i| {
        result = result * i;
    }
    return result;
}

# Computed at compile time; runtime simply loads the constant 3628800
@const $FACT_10 = @comptime factorial(10);

pub @func main() {
    print(FACT_10); # 3628800
}
```

- `@comptime` blocks support variables, arithmetic, `@for` loops, and `@if` branches.
- Loops in `@comptime` are bounded by a configurable iteration cap (default 100,000, configurable via `--comptime-max-loop-iterations`).
