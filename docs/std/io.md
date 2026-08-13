# `std/io`

The `io` standard library module provides utilities for standard input and output operations.

## Functions

### `readLine()`
Reads a single line of input from standard input (stdin).
This function will block execution until a newline character is encountered.

- **Returns:** A `string` containing the read line (without the trailing newline), or `null` if the end of file (EOF) is reached.
- **Example:**
  ```llts
  const io = @import("std/io");
  const std_out = @import("std/debug");
  
  std_out.printLn("Enter your name:", null, null, null, null);
  const name = io.readLine();
  
  std_out.printLn("Hello, {s}!", name, null, null, null);
  ```
