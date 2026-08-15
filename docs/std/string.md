# String (`std/string.lls`)

The `string` module provides a comprehensive set of functions for manipulating and analyzing string values in LLTS. These functions wrap native, highly optimized built-in operations.

## Importing

```llts
const string = @import("std/string");
```

## String semantics

Runtime strings are **byte slices**, not mutable character arrays.

- **Literals** (`"hello"`) are interned in the bytecode chunk (`.name`).
- **Built results** (`concat`, `trim`, `slice`, …) are views into the VM’s unified packed byte heap (`.slice`: `{ offset, len }` into `vm.bytes`).

See also [VM value system](../vm.md#2-value-system--stack-representation) and [bytecode `Value`](../bytecode.md#2-runtime-values-value).

### Assignment copies the handle, not the bytes

```llts
$x = "abc";
$b = x;
```

`$b = x` copies the string **handle** (same interned literal or same arena view). It does **not** duplicate the underlying bytes. Both names refer to the same data until one is reassigned to a different value.

### Strings are immutable

There is no in-place byte mutation. Index **read** works for some representations; index **write** does not:

```llts
$x = "abc";
x[0];        # may work depending on representation
x[0] = "z";  # runtime error: Indexing non-array
```

To change content, produce a **new** string (`string.replaceFirst`, `string.concat`, `string.slice`, …). The original is left unchanged.

### Substrings are views when possible

`string.slice`, `string.substr`, `string.trimStart`, and `string.trimEnd` often return another view into the same arena bytes (zero-copy). Functions that change length (`concat`, `replace`, `padStart`, …) append new bytes and return a new slice.

### Contrast with arrays

| | **String** | **Array** (`[1, 2, 3]`) |
|---|---|---|
| `$b = a` | Shared handle; same bytes | Shared heap block |
| `b[i] = v` | Not allowed | Updates slot; `a[i]` sees it too |
| “Change one element” | Build a new string | In-place index assign |

Arena-allocated **byte buffers** from `@new(a, []byte, n)` are mutable arrays, not `string` values — see [Arrays — `@new`](../usage/arrays.md).

## Functions

### `len(str)`
Returns the length of the string `str` in bytes.

- **Arguments:**
  - `str`: The string to measure.
- **Returns:** An integer representing the length.
- **Example:**
  ```llts
  string.len("hello"); // 5
  ```

### `concat(a, b)`
Concatenates two strings together and returns the resulting new string.

- **Arguments:**
  - `a`: The first string.
  - `b`: The second string.
- **Returns:** A new concatenated string.
- **Example:**
  ```llts
  string.concat("hello", " world"); // "hello world"
  ```

### `substr(str, start, length)`
Returns a substring of `str` starting at the `start` index with the specified `length`. If `start` or `length` exceed the bounds of the string, they are safely capped to the string's actual length.

- **Arguments:**
  - `str`: The source string.
  - `start`: The starting index (0-based).
  - `length`: The maximum number of characters to extract.
- **Returns:** A new string containing the extracted characters.
- **Example:**
  ```llts
  string.substr("hello world", 0, 5); // "hello"
  ```

### `indexOf(str, search)`
Returns the index of the first occurrence of `search` in `str`. If `search` is not found, it returns `-1`.

- **Arguments:**
  - `str`: The source string.
  - `search`: The substring to search for.
- **Returns:** The starting index of the substring, or `-1` if not found.
- **Example:**
  ```llts
  string.indexOf("hello world", "world"); // 6
  string.indexOf("hello world", "zig");   // -1
  ```

### `split(str, sep)`
Splits `str` into an array of substrings separated by `sep`. If `sep` is an empty string, the source string is split into an array of individual characters.

- **Arguments:**
  - `str`: The string to split.
  - `sep`: The separator string.
- **Returns:** An array of strings.
- **Example:**
  ```llts
  string.split("a,b,c", ","); // ["a", "b", "c"]
  string.split("cat", "");    // ["c", "a", "t"]
  ```

### `toUpper(str)`
Converts all lowercase ASCII letters in `str` to uppercase.

- **Arguments:**
  - `str`: The source string.
- **Returns:** A new string in uppercase.
- **Example:**
  ```llts
  string.toUpper("hello"); // "HELLO"
  ```

### `toLower(str)`
Converts all uppercase ASCII letters in `str` to lowercase.

- **Arguments:**
  - `str`: The source string.
- **Returns:** A new string in lowercase.
- **Example:**
  ```llts
  string.toLower("WORLD"); // "world"
  ```

### `trim(str)`
Removes leading and trailing whitespace from `str`.

- **Arguments:**
  - `str`: The source string.
- **Returns:** A new trimmed string.
- **Example:**
  ```llts
  string.trim("  hello  "); // "hello"
  ```

### `replace(str, search, replacement)`
Replaces all occurrences of the `search` string with the `replacement` string inside `str`.

- **Arguments:**
  - `str`: The source string.
  - `search`: The substring to be replaced.
  - `replacement`: The substring to replace it with.
- **Returns:** A new string with the replacements applied.
- **Example:**
  ```llts
  string.replace("hello world", "world", "llts"); // "hello llts"
  ```

### `repeat(str, count)`
Repeats `str` `count` number of times and returns the newly formed string.

- **Arguments:**
  - `str`: The string to repeat.
  - `count`: The number of times to repeat the string.
- **Returns:** A new repeated string.
- **Example:**
  ```llts
  string.repeat("ha", 3); // "hahaha"
  ```

### `startsWith(str, search)`
Checks if `str` begins with the `search` string.

- **Arguments:**
  - `str`: The source string.
  - `search`: The prefix to check for.
- **Returns:** A boolean `true` if `str` starts with `search`, otherwise `false`.
- **Example:**
  ```llts
  string.startsWith("hello world", "hello"); // true
  ```

### `endsWith(str, search)`
Checks if `str` ends with the `search` string.

- **Arguments:**
  - `str`: The source string.
  - `search`: The suffix to check for.
- **Returns:** A boolean `true` if `str` ends with `search`, otherwise `false`.
- **Example:**
  ```llts
  string.endsWith("hello world", "world"); // true
  ```

### `charCodeAt(str, index)`
Returns the ASCII character code of the character at the specified `index`. If the index is out of bounds, it returns `-1`.

- **Arguments:**
  - `str`: The source string.
  - `index`: The index of the character.
- **Returns:** The integer ASCII code, or `-1` if out of bounds.
- **Example:**
  ```llts
  string.charCodeAt("A", 0); // 65
  string.charCodeAt("A", 5); // -1
  ```

### `parseInt(str, base)`
Parses a string into an integer according to the specified mathematical base.

- **Arguments:**
  - `str`: The string to parse.
  - `base`: The mathematical base (radix) for parsing (e.g., `10` for decimal, `16` for hexadecimal).
- **Returns:** The parsed integer, or `0` if parsing fails.
- **Example:**
  ```llts
  string.parseInt("42", 10); // 42
  string.parseInt("FF", 16); // 255
  string.parseInt("abc", 10); // 0
  ```

### `parseFloat(str)`
Parses a string into a floating-point number.

- **Arguments:**
  - `str`: The string to parse.
- **Returns:** The parsed float, or `NaN` if parsing fails.
- **Example:**
  ```llts
  string.parseFloat("3.14"); // 3.14
  ```

### `fromCharCode(code)`
Creates a single-character string from an ASCII code point. 

- **Arguments:**
  - `code`: The ASCII integer code (0-255).
- **Returns:** A 1-byte string character.
- **Example:**
  ```llts
  string.fromCharCode(65); // "A"
  ```

Lengths and indexes are **bytes**. Empty needles: `contains(s, "")` is true; `indexOf(s, "")` is `0`; `replaceFirst` inserts at index 0. `slice` is JS-style (end exclusive, negative indexes from the end). `substr` still clamps negatives to 0.

### `contains(str, search)`
`true` if `search` occurs in `str`.

```llts
string.contains("hello", "ell"); // true
```

### `lastIndexOf(str, search)`
Last index of `search`, or `-1`.

### `indexOfFrom(str, search, from)`
First index of `search` at or after byte `from`, or `-1`.

### `trimStart(str)` / `trimEnd(str)`
ASCII whitespace from the start or end only. Arena strings return a view (no copy).

### `replaceFirst(str, search, replacement)`
Replaces the first occurrence of `search`.

### `slice(str, start, end)`
Byte slice `[start, end)`. Negative `start`/`end` count from the end.

```llts
string.slice("hello", 1, 4); // "ell"
string.slice("hello", -2, 5); // "lo"
```

### `compare(a, b)` / `eql(a, b)`
`compare` returns `-1` / `0` / `1`. `eql` is byte equality.

### `splitMax(str, sep, n)`
At most `n` parts; the last part is the unsplit remainder. Empty `sep` splits by byte the same way: `splitMax("abcde", "", 3)` → `["a","b","cde"]`.

### `join(arr, sep)`
Joins a heap array (from `split`) or a `std.list` of strings. Writes into the string arena (no extra buffer).

### `padStart(str, len, pad)` / `padEnd(str, len, pad)`
Pads with repeating `pad` until byte length `len`. Empty `pad` or `len <= len(str)` returns `str`.

### `isEmpty(str)` / `isBlank(str)`
`isEmpty` is `len == 0`. `isBlank` is empty after ASCII trim.
