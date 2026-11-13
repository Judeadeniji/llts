# Variables, Bindings & Scoping

LLTS uses an explicit, unambiguous binding model designed to make state creation, mutability, and lexical lifetimes immediately visible in source code.

---

## The `$` Declaration-Only Sigil

In LLTS, variable bindings are introduced using the `$` sigil. 

**Rule:** The `$` sigil is used **only at the declaration site**. All subsequent references, assignments, and expressions omit the sigil:

```llts
# Declaration site: $ indicates introducing a new binding
$count = 0;

# Mutation site: no $
count = count + 1;

# Expression / read site: no $
print(count);
```

### Why a Declaration-Only Sigil?
1. **Unambiguous Grammars:** It eliminates the classic C/JavaScript ambiguity between assignment (`x = 5`) and declaration (`var x = 5`).
2. **Visual Clarty:** When scanning code, every new identifier introduction pops out immediately without needing keyword noise (`let`, `var`).
3. **No Redundant Sigil Noise:** Unlike PHP, Bash, or Perl, the `$` is not a permanent prefix on the identifier. Function bodies remain clean and ergonomic.

> [!IMPORTANT]
> Function parameters and loop capture variables do **not** use the `$` sigil. They are declared by their enclosing parameter lists or loop heads:
> ```llts
> @func add(a: i64, b: i64): i64 { return a + b; }
> @for (0..5) |i| { print(i); }
> ```

---

## Mutable Bindings

A bare `$name = expr;` declaration introduces a mutable variable:

```llts
$total = 100;
total = total + 50;  # OK: total is mutable
```

### Type Inference vs Explicit Annotations

LLTS supports local type inference. If a type annotation is omitted, the compiler infers the variable's type from the initialization expression:

```llts
$inferred_int = 42;          # Inferred as i64
$inferred_float = 3.14;      # Inferred as f64
$inferred_str = "hello";     # Inferred as string
```

To enforce an exact numeric width or interface shape, specify an explicit type annotation after the identifier:

```llts
$small: i8 = 127;
$byte_val: u8 = 255;
$buffer: [4]u8 = [0, 0, 0, 0];
```

If the initializer value does not match or cannot implicitly widen to the annotated type, the compiler issues a compile-time type mismatch error.

---

## Immutable Constants: `@const`

To declare an immutable binding, prefix the declaration with `@const`:

```llts
@const $MAX_RETRIES: i64 = 5;
@const $PI: f64 = 3.141592653589793;
```

### Rebinding Prevention
`@const` bindings are strictly immutable. Any attempt to reassign or rebind them triggers a compile-time error:

```llts
@const $limit = 10;
limit = 20; # COMPILE ERROR: Cannot assign to constant 'limit'
```

### Deep Immutability on Structs
The immutability guarantee is deep. If a struct is bound with `@const`, its fields cannot be mutated:

```llts
@struct Point {
    x: i64;
    y: i64;
}

@const $ORIGIN = Point { x: 0, y: 0 };
ORIGIN.x = 10; # COMPILE ERROR: Cannot mutate field of constant
```

### Address-of Restriction
Taking the address of a compile-time constant is rejected:

```llts
@const $C = 42;
$p = &$C; # COMPILE ERROR: Cannot take address of constant
```

---

## Lexical Scoping & Block Lifetimes

LLTS is strictly lexically scoped using curly braces `{ ... }`. Every block defines a local scope frame:

```llts
pub @func main() {
    $outer = 1;

    {
        $inner = 2;
        print(outer + inner); # 3
    }

    # print(inner); # COMPILE ERROR: Unknown identifier 'inner'
}
```

### Variable Shadowing
An inner block can declare a variable with the same name as an outer variable. The compiler permits this but emits a helpful diagnostic warning to prevent unintentional bugs:

```llts
$x = 10;
{
    $x = "shadowed"; # Warning: 'x' shadows variable 'x' declared at line 1
    print(x);        # "shadowed"
}
print(x);            # 10
```

---

## Labeled Block Expressions

Blocks in LLTS can produce values directly in expression positions using labeled break statements:

```llts
pub @func main() {
    $value = compute: {
        $a = 10;
        $b = 20;
        @if (a + b > 25) {
            break :compute a * 2;
        }
        break :compute b;
    };

    print(value); # 20
}
```

- A label precedes the block with a colon suffix (`label: { ... }`).
- `break :label <expr>;` terminates the block and supplies its evaluated result.
- Every control flow path within the block must terminate in a matching `break :label`.

---

## Visibility & Top-Level Bindings

Bindings can be declared at module scope (outside of any function):

```llts
# Private top-level constant (visible only within this file)
@const $BUFFER_SIZE: usize = 4096;

# Public top-level constant (exported to importers)
pub @const $VERSION: string = "1.0.0";

# Public mutable global (visible to importers)
pub $global_counter: i64 = 0;
```

When imported by another file, public top-level declarations are accessed via the module namespace (`mod.VERSION`). Private module declarations remain inaccessible.

---

## Unused Variable Diagnostics

The LLTS compiler analyzes binding reachability and variable reads. If a variable is declared but never read, the compiler produces an unused variable warning:

```llts
pub @func calculate() {
    $unused = 123; # Warning: unused variable 'unused'
    return 42;
}
```
