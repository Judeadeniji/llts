# Control Flow in LLTS

LLTS treats control flow constructs as both statements and first-class value-producing expressions. Conditionals (`@if`), pattern matches (`@switch`), and blocks can yield values via explicit `break <value>;` statements.

---

## 1. Conditionals (`@if`)

### Standard Statement Form
The standard `@if` statement evaluates a boolean condition:

```lls
$score = 85;

@if (score >= 90) {
    print("Grade: A");
} @else @if (score >= 80) {
    print("Grade: B");
} @else {
    print("Grade: C");
}
```

Parentheses around the condition and braces around the body blocks are required.

### Optional Capture Unwrapping
If the condition evaluates an optional value (`?T`), the payload can be safely unwrapped into a local variable within the then-branch:

```lls
$maybe_name: ?string = "Alice";

@if (maybe_name) |name| {
    # 'name' is non-optional string
    print("Hello, ", name);
} @else {
    print("Hello, stranger");
}
```

### Value-Producing `@if` Expression
An `@if` block can produce a value and be assigned to a variable. Every branch must yield a value using `break <value>;`, and an `@else` branch is strictly required:

```lls
$status_code = 200;

$message = @if (status_code == 200) {
    break "Success";
} @else @if (status_code == 404) {
    break "Not Found";
} @else {
    break "Unknown Status";
};

print(message); # "Success"
```

> **Rules for Value-Producing `@if`:**
> 1. An `@else` arm is mandatory (so all execution paths produce a value).
> 2. Every branch must terminate with `break <value>;`. Falling through without `break` is a compile error.
> 3. Values returned across all branches must have compatible types.

---

## 2. Pattern Matching (`@switch`)

The `@switch` construct provides structural branching over numbers, strings, enums, and error sets.

### Basic Syntax
```lls
$role = "admin";

@switch (role) {
    "admin" => {
        print("Full access");
    },
    "editor", "author" => {
        print("Content access");
    },
    @else => {
        print("Read-only access");
    },
}
```

- **Multiple patterns per arm:** Separate patterns with commas (`"editor", "author" =>`).
- **Default fallback:** `@else => { ... }` handles all unmatched values.

### Matching on Enums and Error Sets
`@switch` works with enum and error variants, narrowing types within prongs:

```lls
@enum Level { Debug, Info, Error }

$lvl = Level.Info;
@switch (lvl) {
    Level.Debug => { print("debug"); },
    Level.Info => { print("info"); },
    Level.Error => { print("error"); },
}
```

### Matching on Strings
Strings are first-class `@switch` operands in both statement and value-producing expressions:

```llts
pub @func method_category(method: string): string {
    return @switch (method) {
        "GET", "HEAD" => { break "safe"; },
        "POST", "PUT", "PATCH", "DELETE" => { break "idempotent_or_unsafe"; },
        @else => { break "unknown"; },
    };
}
```

> [!IMPORTANT]
> **The `@else` Arm is Required for Strings:**
> Unlike finite `@enum` sets or `@error` sets where the compiler can verify compile-time exhaustiveness, `string` represents an open, infinite set of values. Therefore, string switches—especially value-producing `@switch` expressions—must include an `@else` fallback prong.

- **Backend Lowering:** Bytecode VM evaluates string equality via `OP_EQUAL`. The native Zig emitter translates string `@switch` blocks into branch chains calling `rt.arith.eqStr(...)`, bypassing Zig's integer-only `switch` constraint.



### Value-Producing `@switch`
Like `@if`, a `@switch` can evaluate directly to a value using `break <value>;`:

```lls
$count = 3;
$label = @switch (count) {
    0 => { break "none"; },
    1 => { break "single"; },
    2, 3 => { break "a few"; },
    @else => { break "many"; },
};
```

### Labeled Switch Continue (`continue :label new_value;`)
LLTS supports Zig-style labeled `@switch` continuation. An arm can store a new scrutinizing value and restart matching at the labeled `@switch`:

```lls
$state = 1;
$result = 0;

sw: @switch (state) {
    1 => {
        result = result + 10;
        continue :sw 2; # Transition state and jump to matching 2
    },
    2 => {
        result = result + 100;
        continue :sw 3; # Transition state and jump to matching 3
    },
    3 => {
        result = result + 1;
    },
    @else => {},
}

print(result); # 111
```

---

## 3. Loops (`@for`)

The `@for` keyword unifies range-based loops, while-style conditional loops, and collection iterations.

### 1. Range Loops (`start..end`)
Range loops iterate over an integer interval. The upper bound is **exclusive**:

```lls
# Iterates 0, 1, 2, 3, 4
@for (0..5) |i| {
    print("i:", i);
}

# Captureless range loop (runs 3 times)
@for (0..3) {
    print("ping");
}
```

### 2. Condition Loops (While-style)
Passing a boolean condition turns `@for` into a condition loop:

```lls
$counter = 0;
@for (counter < 5) {
    counter = counter + 1;
}

# Infinite loop
@for (true) {
    # do work...
    break;
}
```

### 3. Collection & Slice Iteration
Passing a slice or array iterates over each element:

```lls
$primes = [2, 3, 5, 7, 11];

@for (primes) |p| {
    print("prime:", p);
}
```

---

## 4. Loop Control & Labels

### `break` and `continue`
- `break` immediately terminates the innermost enclosing loop or switch.
- `continue` skips the remainder of the current iteration and begins the next.

```lls
@for (0..10) |i| {
    @if (i % 2 == 0) {
        continue; # Skip even numbers
    }
    @if (i > 7) {
        break;    # Stop once past 7
    }
    print(i);     # 1, 3, 5, 7
}
```

### Labeled Loops
When loops are nested, prefix the loop with `label:` to break or continue a specific outer loop:

```lls
outer: @for (0..5) |x| {
    inner: @for (0..5) |y| {
        @if (x + y == 6) {
            print("Found target sum:", x, y);
            break :outer; # Breaks directly out of outer loop
        }
    }
}
```

---

## 5. Labeled Block Expressions

Any block can be labeled and used as a value-producing expression. Execution exits the block with the value supplied to `break :label <value>;`:

```lls
$sum = compute: {
    $a = 15;
    $b = 27;
    @if (a < 0) {
        break :compute 0; # Early exit
    }
    break :compute a + b;
};

print(sum); # 42
```

- Variables declared inside the labeled block are strictly local to that block.
- Labeled blocks can be nested, and `break :label` exits directly to the specified target:

```lls
$res = outer: {
    $val = inner: {
        break :inner 10;
    };
    break :outer val * 2;
};

print(res); # 20
```

---

## 6. Function Returns (`return`)

The `return` statement exits the enclosing function:

```lls
@func find_first_positive(items: [4]i64): i64 {
    @for (items) |n| {
        @if (n > 0) {
            return n; # Early exit with value
        }
    }
    return 0;
}
```

- Bare `return;` is used in functions returning `void`.
- Returning from within a block or loop immediately exits the entire function, executing any active `defer` blocks before exiting.
