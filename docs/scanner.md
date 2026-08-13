# Scanner (Lexer) Documentation

This document describes the design, architecture, and behavior of the `llts-zig` scanner (lexer), located in `src/scanner/`. The scanner's primary responsibility is converting a raw source code string into a sequence of tokens.

## Architecture & Data Flow

The scanner acts as the first phase of the frontend, converting `[]const u8` source into `std.ArrayList(Token)`. 

1. **Initialization:** A `Scanner` context is created with an allocator, source string, and file path.
2. **Execution:** `scanNext()` is repeatedly called to extract the next logical token.
3. **Completion:** An `eof` token is appended, and a `ScanResult` containing the token list is returned.

### Files Overview
- `root.zig`: The entry point for scanning (`scan` function) and the core character-dispatch loop.
- `tokens.zig`: Defines the `Token` struct, `TokenType` enum, and `ScanResult`.
- `ctx.zig`: Defines the `Scanner` state struct, `ScanError` types, and utilities for peeking and pushing tokens.
- `keywords.zig`: Hardcodes regular keywords, compiler symbols (prefixed with `@`), and delimiters.
- `numbers.zig`: Contains logic for scanning decimal, hexadecimal, binary, and octal numeric literals.
- `strings.zig`: Contains logic for scanning string literals and escape sequences.

## Token Types & Structures

### `TokenType`
The scanner categorizes tokens into the following types:
- **Identifiers & Keywords:** `keyword`, `identifier`, `compiler_keyword` (e.g., `@func`), `v_register` (e.g., `$r0`)
- **Literals:** `string`, `number` (decimal/float), `hex`, `octal`, `binary`, `boolean`
- **Punctuation:** `delimiter` (e.g., `,`, `;`, `{`, `...`), `type_decl`
- **Operators:** `bin_op`, `unary_op`, `assign_op`
- **Control:** `eof`

### `Token` Struct
```zig
pub const Token = struct {
    type: TokenType,
    value: []const u8, // Owned slice (dupe'd by the scanner)
    line: u32,
    column: u32,
};
```
*Note:* The `value` slice of each token is explicitly allocated (via `allocator.dupe`) and owned by the `ScanResult`. The consumer must call `deinitScanResult` to free the tokens.

## Scanning Logic & Grammar Rules

### 1. Identifiers and Keywords
- **Regular Identifiers:** Start with an alphabetic character (`[a-zA-Z_]`) and continue with alphanumeric characters. If the matched string exactly matches a keyword or boolean (`true`/`false`), it is appropriately classified.
- **Compiler Keywords:** Start with `@`, followed by an alphanumeric string (e.g., `@if`, `@struct`). Will throw `InvalidCompilerKeyword` if the keyword is not recognized in the `compiler_symbols` list.
- **Registers:** Start with `$`, followed by an alphanumeric string (e.g., `$x`). Will throw `ExpectedRegister` if empty.

### 2. Member Expressions
If an identifier or a register is immediately followed by a dot (`.`), the scanner treats it as a member expression and will proactively parse the sequence (e.g., `a.b.c`). 
- The base token must be `v_register` or `identifier`.
- It emits the base token, followed by a `delimiter` for `.`, followed by the member `identifier`.

### 3. Number Literals
- **Hexadecimal:** Starts with `0x` or `0X` followed by `[0-9a-fA-F]`.
- **Binary:** Starts with `0b` or `0B` followed by `[01]`.
- **Octal:** Starts with `0o` or `0O` followed by `[0-7]`.
- **Decimal & Floats:** Standard decimal digits. If it encounters a dot (`.`) followed by a digit, it continues matching as a float. (e.g. `123`, `123.456`).

### 4. String Literals
- Starts with either double `"` or single `'` quotes.
- **Constraints:** Multiline strings are *not* supported. Encountering a newline `\n` inside a string literal throws `error.MultilineString`.
- **Escape Sequences:** Supports standard escape characters like `\n`, `\r`, `\t`, `\\`, `\"`, `\'`.

### 5. Comments
- Comments begin with a hash `#` and consume all characters until the end of the line (`\n`). They are discarded and do not produce tokens.

### 6. Operators & Delimiters
- Checks for three-character tokens (e.g., `...` delimiter).
- Checks for two-character operators based on definitions in `shared/ops.zig` (e.g., `==`, `>=`, `+=`).
- Falls back to single-character operators and delimiters.

## Error Handling
The scanner returns standard Zig errors via the `ScanError` set, which includes:
- `UnexpectedCharacter`: Encountered an unrecognizable character.
- `UnterminatedString`: End of file reached before string closing quote.
- `MultilineString`: Newline character found in an open string literal.
- `ExpectedRegister`: Found a bare `$` with no identifier.
- `ExpectedCompilerKeyword`: Found a bare `@` with no identifier.
- `InvalidCompilerKeyword`: Recognized an `@` token, but the identifier does not match valid compiler symbols.
- `InvalidMember`: Encountered an invalid base or property during a `.` member expression scan.

Internally, when a lexical error occurs, the scanner uses `errors/report.zig` (specifically `reportSourceErrorWithFrame`) to emit rich, context-aware diagnostics. This output is routed through the robust `src/io/` subsystem for accurate POSIX terminal coloring. It also hooks into `errors/diag.zig` to ensure the compiler's CLI does not print duplicate generic error messages upon failure.

## Usage Example

```zig
const std = @import("std");
const scanner = @import("scanner.zig");

var result = try scanner.scan(allocator, "$x = 42\n", "script.lls");
defer scanner.deinitScanResult(&result);

for (result.tokens.items) |token| {
    std.debug.print("Token: {s} ('{s}') at {d}:{d}\n", .{
        @tagName(token.type), token.value, token.line, token.column
    });
}
```
