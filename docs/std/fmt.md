# `std/fmt`

The `std/fmt` package implements formatted I/O with functions analogous to Go's `fmt` package.

## Overview

```llts
@const $fmt = @import("std/fmt");

// Formatted printing to stdout
fmt.printf("Hello, %s! You have %d new notifications.\n", "Alice", 5);

// Formatting strings in memory
$msg = fmt.sprintf("Score: %.2f (hex: 0x%x)", 98.65, 255);

// Unformatted printing
fmt.println("Process completed:", true);
```

## Format Verbs

### General
* `%v`: Default format for the value (strings unquoted, arrays formatted as `[1 2 3]`, maps as `map[k:v]`, structs as `{f1 f2}`).
* `%+v`: Adds struct field names and detailed error payloads.
* `%#v`: Go/LLTS-syntax representation of the value (strings quoted, slices prefixed).
* `%T`: Type of the value (`int`, `string`, `bool`, `float`, `[]byte`, `array`, `error`, etc.).
* `%%`: Literal percent sign.

### Boolean
* `%t`: The word `true` or `false`.

### Integer
* `%d`: Base 10 decimal.
* `%b`: Base 2 binary (with `#`: `0b1010`).
* `%o`: Base 8 octal (with `#`: `0755`).
* `%O`: Base 8 octal with `0o` prefix (`0o755`).
* `%x`: Base 16 lowercase hexadecimal (with `#`: `0x...`).
* `%X`: Base 16 uppercase hexadecimal (with `#`: `0X...`).
* `%c`: Unicode code point / character represented by the integer.
* `%q`: Single-quoted character literal safely escaped with Go/LLTS syntax (`'a'`, `'\n'`).
* `%U`: Unicode format: `U+1234` (with `#`: `U+0041 'A'`).

### Floating-Point
* `%f`, `%F`: Decimal point without exponent, e.g. `123.456000` (default precision 6).
* `%e`, `%E`: Scientific notation, e.g. `1.234560e+02` or `1.234560E+02`.
* `%g`, `%G`: Compact float representation (%e for large/small exponents, %f otherwise).

### String & Byte Slices
* `%s`: Uninterpreted string or byte slice contents.
* `%q`: Double-quoted string safely escaped (`"hello\nworld"`). With `#`: raw backquoted string if possible.
* `%x`, `%X`: Hex-encoded bytes (2 characters per byte, with optional space flag `% x`).

### Pointer
* `%p`: Base 16 pointer notation with leading `0x`.

## Flags, Width, and Precision

* `+`: Always print a sign for numbers (`%+d`), or ASCII-only in `%q`.
* `-`: Left-justify within field width (pad with spaces on the right).
* `#`: Alternative format (`0x`, `0b`, `0o`, `%#v`, `%#q`).
* `' '` (space): Leave space for positive number sign (`% d`).
* `0`: Pad with leading zeros instead of spaces (`%05d`).
* Width: Minimum width of the field (`%10s`, `%-10s`).
* Precision: Maximum characters for strings (`%.3s`), decimal digits for floats (`%.2f`), or minimum digits for integers (`%.4d`).
* Dynamic width & precision: `%*s`, `%.*f`.
* Argument indexing: `%[2]s %[1]d` to access arguments out of order.

## Functions

### `sprintf(format, ...args): string`
Formats according to a format specifier and returns the resulting string.

### `printf(format, ...args): int`
Formats according to a format specifier and writes to standard output. Returns the number of bytes written.

### `fprintf(w, format, ...args): int`
Formats according to a format specifier and writes to destination `w` (an integer file descriptor or an object with a file descriptor `.fd`).

### `sprint(...args): string`
Formats using default `%v` format for its operands and returns the resulting string. Spaces are added between operands when neither is a string.

### `sprintln(...args): string`
Formats using default `%v` format for its operands and returns the resulting string. Spaces are always added between operands, and a newline is appended.

### `print(...args): int`
Writes `sprint` output to standard output.

### `println(...args): int`
Writes `sprintln` output to standard output.

### `fprint(w, ...args): int`
Writes `sprint` output to `w`.

### `fprintln(w, ...args): int`
Writes `sprintln` output to `w`.

### `errorf(format, ...args): error`
Formats according to a format specifier and returns an error value.
