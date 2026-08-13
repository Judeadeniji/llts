# String (`std/string.lls`)

The `string` module provides a comprehensive set of functions for manipulating and analyzing string values in LLTS. These functions wrap native, highly optimized built-in operations.

## Importing

```llts
const string = @import("std/string");
```

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
