# LLTS Language Reference

Comprehensive guide to syntax, control flow, types, memory semantics, errors, and modules in LLTS.

## Declarations and Control Flow

Bindings are introduced with `$`; the sigil is only used at the declaration site. `@const` makes a binding immutable. Comments start with `#`.

```lls
@const $limit = 3;

@func classify(n: i64): string {
    @if (n < 0) { return "negative"; }
    @if (n == 0) { return "zero"; }
    return "positive";
}

pub @func main() {
    $total = 0;
    @for (0..limit) |i| {
        total += i;
    }

    $label = @switch (classify(total)) {
        "zero" => { break "none"; },
        "positive" => { break "some"; },
        @else => { break "unknown"; },
    };
    print(label);
}
```

- `@if` / `@else`, `@for` (range, condition, and iterable forms), and `@switch` expressions.
- `break`/`continue`, including labeled loops.
- `|>` pipes a value as the first argument of a call.
- Fenced template literals with `${expr}` interpolation.

## Operators

- **Arithmetic:** `+`, `-`, `*`, `/`, `%`, wrapping `+%` / `-%` / `*%`, and power via `^` or `**`.
- **Bitwise** (integers only): `&`, `|`, `~` (binary XOR / unary NOT), `<<`, `>>`, plus compounds `&=`, `|=`, `~=`, `<<=`, `>>=`.
- Shift counts must be in `0..63` (inclusive of 0, exclusive of 64). Negative or oversized counts are a runtime error (`Shift amount out of range`); `>>` is an arithmetic (sign-extending) shift.
- Bitwise and shift results keep the left operand's width. Native builds range-check shift results, so widen first (`@as(i64, x) << n`) when the shift may move bits out of the operand's width.
- **Comparison and logic:** `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`.

## Types

| Kind | Syntax |
| --- | --- |
| Integers | `i8` … `i64`, `u8` … `u64`, `u1` / `bool` |
| Floats | `f32`, `f64` |
| Strings | `string` (a `[]byte` value) |
| Arrays / slices | `[N]T`, `[]T` |
| Tuples | `[A, B]` |
| Pointers | `*T`, `?*T` |
| Optionals / unions | `?T`, `A \| B` |
| Shapes | `{ x: i64; y: i64; }` |
| Nominal / transparent aliases | `@type UserId = i64;`, `@alias Id = i64;` |
| Structs / enums / errors | `@struct`, `@enum`, `@error` |
| Unit / bottom | `void`, `never` |

`@type` creates a distinct nominal type; `@alias` is transparent. Structs, enums, and typed error sets compose with unions and `@switch` narrowing.

## Memory

Aggregates are frame-local. Returning them is rejected unless the value is a flat scalar struct that can be cloned safely:

```lls
@struct Node {
    value: i64;
    next: ?*Node;
}

@func head(node: *Node): i64 {
    return node.value;
}

pub @func main() {
    $a = Node { value: 1, next: null };
    $b = Node { value: 2, next: &a };
    print(head(&b));
}
```

Native allocation is not currently a core-language operation. A future standard-library API will own allocation policy, growth, resizing, freeing, and failure behavior; it will not require a compiler-known allocator method name or a total capacity known in advance. The bytecode compiler temporarily retains the legacy `@new(allocator, T)` intrinsic for VM compatibility. `defer` and `errdefer` run cleanup on scope exit and on the error path respectively.

## Errors

```lls
@error ParseError { Empty, Invalid }

@func parse(ok: bool): i64 | ParseError {
    @if (!ok) {
        return ParseError.Invalid;
    }
    return 42;
}

pub @func main() {
    $value = parse(false);
    @if (@isError(value)) {
        print("invalid input");
    }
}
```

Errors can also be created dynamically with `error("message")`. Unwrap typed errors with `?`, test any error value with `@isError`, and branch on typed error sets with `@switch`. Dynamic errors are message-only (`.message`); they do not carry a code or payload.

## Modules

```lls
# math.lls
pub @func square(x: i64): i64 {
    return x * x;
}

pub @const $answer = 42;
```

```lls
# main.lls
@const $math = @import("./math.lls");

print(math.square(math.answer));
pub @func main() {}
```

Relative imports are explicit. Only `pub` declarations are visible outside their module.
