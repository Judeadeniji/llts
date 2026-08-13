# `llts` Control Flow & Block Scoping

This document details the conditional logic and labeled block execution rules in the `llts` programming language. It is optimized for agent consumption to quickly understand AST structures, syntax rules, and data flow.

## 1. Conditionals (`@if` / `@else`)

Conditional statements in `llts` use keyword prefixes with the `@` symbol, similar to Zig's builtin functions or compiler directives.

### Rules and Constraints:
* **Keywords:** Must use `@if` and `@else`.
* **Condition Grouping:** The test expression must always be wrapped in parentheses `()`.
* **Block Enclosure:** Braces `{}` are mandatory for the body of the conditional. Single-line statements without braces are not permitted.
* **Variables:** Declaration requires the `$` prefix (e.g., `$a = 10;`), but variable usage does not (e.g., `a > b`).

### Syntax Pattern
```llts
$a = 10;
$b = 20;

@if (a > b) {
    print("a is greater than b");
} @else @if (a == b) {
    print("a is equal to b");
} @else {
    print("a is less than b");
}
```

## 2. Labeled Blocks and Expressions

Blocks in `llts` can act as evaluatable expressions when labeled. This allows scoped logic with complex early exits to yield a single value to a variable.

### Syntax Pattern
* **Block Label:** Declared with an identifier followed by a colon `label: { ... }`.
* **Yielding Values:** Use `break :label <expression>;` to yield a value from the block. The label identifier in the break statement must be prefixed with a colon `:`.

```llts
$sum = compute: {
    $a = 10;
    $b = 32;
    break :compute a + b;
};
```

### Early Exits
Labeled blocks facilitate early exits from specific scopes without requiring helper functions.

```llts
$abs = absv: {
    $n = 0 - 7;
    @if (n < 0) {
        break :absv 0 - n; # Early exit triggers here
    }
    break :absv n;
};
```

### Nested Labels and Scope Breaking
In nested block structures, a `break` statement can target any outer named label. This will immediately terminate all inner scopes and yield the value to the targeted outer block.

```llts
$skip = outer: {
    inner: {
        # This will break out of both `inner` and `outer`, yielding 99 to $skip
        break :outer 99;
    }
    break :outer 0;
};
```

### Explicit Result Typing
Variables receiving the result of a block expression can include type annotations.

```llts
$flag: bool = check: {
    break :check true;
};
```

## 3. Supplementary: Loops
For complete documentation on iteration, please see the dedicated [Loops](loops.md) documentation.

