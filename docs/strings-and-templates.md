# Strings & Multiline Templates

In LLTS, text is handled through the primitive `string` type (an immutable byte slice) and multiline fenced template literals with `${expr}` interpolation.

---

## The `string` Type

The `string` type in LLTS represents an immutable view over contiguous bytes (`[]u8` / `[]byte`):

```llts
$greeting: string = "Hello, world!";
print(greeting);
```

- **Immutability:** Strings cannot be mutated in-place.
- **UTF-8 Clean:** String literals contain UTF-8 encoded bytes.
- **Length:** Use the built-in `len(str)` function to obtain the length in bytes:
  ```llts
  $len = len(greeting); # 13
  ```

---

## Single-Line String Literals

Single-line strings are enclosed in double quotes (`"..."`) or single quotes (`'...'`):

```llts
$double_quoted = "Hello, LLTS!";
$single_quoted = 'Hello, LLTS!';
```

### Supported Escape Sequences

| Escape | Meaning |
|---|---|
| `\n` | Line feed / newline (ASCII 10) |
| `\r` | Carriage return (ASCII 13) |
| `\t` | Horizontal tab (ASCII 9) |
| `\\` | Literal backslash |
| `\"` | Literal double quote |
| `\'` | Literal single quote |
| `\$` | Literal dollar sign |
| `\0` | Null byte (ASCII 0) |
| `\xHH` | 2-digit hexadecimal byte value (e.g. `\x1B` for ESC) |

---

## Multiline Fenced Templates

LLTS features multiline template literals delimited by triple backticks (`` ``` ... ``` ``).

```llts
$query = ```
SELECT id, name, email
FROM users
WHERE active = true;
```;

print(query);
```

### Syntax and Indentation Rules

1. **Opening Fence:** The opening `` ``` `` must be followed only by optional spaces/tabs and then a mandatory newline. The body begins on the next line.
2. **Closing Fence:** The closing `` ``` `` may be indented to match surrounding code; trailing delimiters like `;` belong after the fence:
   ```llts
   pub @func main() {
       $block = ```
           First line
           Second line
       ```;
       print(block);
   }
   ```
3. **Preservation of Whitespace:** Interior line indentation is preserved exactly as written.
4. **Structural Newline Dropping:** Only the single final newline directly preceding the closing `` ``` `` fence is trimmed away so that single-line bodies or trailing text don't accumulate unintended extra line breaks.
5. **Empty Templates:** An empty body (`` ``` `` followed by newline and immediate closing `` ``` ``) evaluates to an empty string `""` with `len(s) == 0`.

---

## String Interpolation: `${expr}`

Template literals support embedded expressions within `${...}` holes:

```llts
$user = "Alice";
$score = 98;

$report = ```
Player: ${user}
Final Score: ${score}
Rating: ${@if (score >= 90) { break "A"; } @else { break "B"; }}
```;

print(report);
```

### Interpolation Constraints & Rules
- **Expressions Only:** Holes accept any valid LLTS expression (variables, arithmetic, function calls, `@if` / `@switch` expressions). Statements, variable declarations (`$x = 1;`), and semicolons are forbidden inside `${...}`.
- **Literal Dollars:** A bare `$` not followed by `{` is treated as a normal literal dollar character:
  ```llts
  $price = 25;
  $label = ```Total: $${price}```; # Prints "Total: $25"
  ```
- **Escaping Holes:** To emit a literal `${` without triggering interpolation, escape the dollar sign: `\${expr}`.
- **Desugaring:** The compiler lowers template literals into `@concat(...)` calls at compile-time with zero runtime overhead.

---

## String Operations

### 1. Element Count: `len(str)`
The global `len()` function returns the byte count:

```llts
$s = "hello";
print(len(s)); # 5
```

When called on an immutable `@const` string, `len()` is folded by the compiler into a compile-time constant:

```llts
@const $NAME = "Antigravity";
@const $NAME_LEN = len(NAME); # Constant folded to 11
```

### 2. Byte Slicing
Strings can be sliced to create subviews:

```llts
$text = "abcdef";
$sub = text[1..4]; # "bcd"
$head = text[..3]; # "abc"
$tail = text[3..]; # "def"
```

### 3. Native Byte Indexing
In native compilation, indexing a string returns its byte value (`u8`):

```llts
$msg = "A";
$first_byte: u8 = msg[0]; # 65 (ASCII for 'A')
```

### 4. String Concatenation: `@concat`
Multiple strings and byte slices can be joined together using the `@concat` intrinsic:

```llts
$first = "foo";
$second = "bar";
$combined = @concat(first, "-", second);
print(combined); # "foo-bar"
```

### 5. String Equality
Strings are compared by byte content using `==` and `!=`:

```llts
$a = "apple";
$b = "apple";
$c = "orange";

print(a == b); # true
print(a != c); # true
```

### 6. Byte Iteration with `@for`
You can iterate over the bytes of a string directly using a collection loop:

```llts
$greeting = "ABC";
@for (greeting) |b| {
    print(b); # prints byte values 65, 66, 67
}
```

---

### 7. Pattern Matching with `@switch`

Strings can be directly inspected and dispatched using `@switch` in both statement and value-producing expression forms:

```llts
pub @func handle_route(path: string): string {
    return @switch (path) {
        "/", "/index.html" => {
            break "home";
        },
        "/about", "/contact" => {
            break "info";
        },
        "/api/v1/health" => {
            break "healthy";
        },
        @else => {
            break "not_found";
        },
    };
}
```

> [!IMPORTANT]
> **The `@else` Arm is Required for Strings:**
> Unlike finite `@enum` sets or `@error` sets where the compiler can verify compile-time exhaustiveness, `string` represents an open, infinite set of values. Therefore, string switches—especially value-producing `@switch` expressions—must include an `@else` fallback prong.

#### String Switch Semantics & Constraints
- **Multi-pattern prongs:** Comma-separated string literals match any of the alternatives (e.g. `"GET", "HEAD" => { ... }`).
- **Value expressions:** Yield values from match arms using `break <val>;`.
- **Labeled continuation (`continue :label <new_string>;`):** You can implement state machines by continuing into a labeled string switch with a new string state:
  ```llts
  $step: string = "start";
  flow: @switch (step) {
      "start" => {
          print("step 1");
          continue :flow "done";
      },
      "done" => {
          print("finished");
      },
      @else => {},
  }
  ```
- **Backend lowering:** 
  - **VM:** Uses `OP_GET_LOCAL` and `OP_EQUAL` with byte slice comparison.
  - **Native backend:** Because Zig's native `switch` statement only permits integers and enums, the LLTS native backend automatically lowers string `@switch` statements into optimized equality branch chains (`rt.arith.eqStr(...)`).

