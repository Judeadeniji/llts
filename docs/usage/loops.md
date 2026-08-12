# Loops in LLTS

This document outlines the loop mechanisms in the LLTS programming language. It is optimized for agents generating or analyzing LLTS code.

## 1. Syntax & Iterators

The standard loop in LLTS is the `@for` loop, iterating over a sequence (commonly a numeric range).

```llts
@for (0..5) |i| {
    // i takes values 0, 1, 2, 3, 4
}
```

### Key Components:
- **`@for` Keyword**: Required prefix for all loop statements.
- **Range Operator (`..`)**: Represents a range from `start` (inclusive) to `end` (exclusive). In `0..5`, the loop will execute for `0, 1, 2, 3, 4`.
- **Iterator Capture (`|var|`)**: The current value of the iteration is bound to the variable specified between the pipe characters. Its scope is strictly limited to the block of the `@for` loop.

## 2. Loop Controls: `break` and `continue`

LLTS supports standard loop control statements:

- **`continue;`**: Terminates the current iteration and jumps to the next evaluation of the loop iterator.
- **`break;`**: Immediately terminates the execution of the loop and transfers control to the statement following the loop block.

```llts
@for (0..10) |i| {
    @if (i == 5) {
        continue; // Skips printing 5
    }
    @if (i == 8) {
        break;    // Terminates loop at 8 (9 and 10 are never reached)
    }
    print("i is", i);
}
```

## 3. Labeled Loops and Nested Control

When dealing with nested loops, you can assign an explicit label to a loop block. This allows loop control statements (like `break`) to target a specific loop instead of defaulting to the innermost one.

### Syntax Rules for Labels:
- **Label Definition**: `label_name:` directly preceding the `@for` keyword.
- **Label Reference**: Target a label using `:label_name` within a `break` or `continue` statement.

```llts
outer: @for (0..3) |x| {
    inner: @for (0..3) |y| {
        @if (x == 1 && y == 1) {
            print("Breaking outer at 1,1");
            break :outer; // Exits the 'outer' loop completely
        }
        print("x", x, "y", y);
    }
}
```

## Agent Constraints & Checks

- **Prefixes:** Verify that `for` is always prefixed with `@` (`@for`).
- **Pipes:** Iterators must be enclosed in `|` (e.g., `|item|`). 
- **Colons in Break:** When breaking out of a labeled loop, ensure a colon precedes the label name in the break statement (`break :my_label;`).
- **Colons in Labels:** When defining a label, ensure a colon trails the label name (`my_label: @for ...`).
- **Exclusive Range Ends:** Keep in mind that `start..end` is exclusive of `end`.
