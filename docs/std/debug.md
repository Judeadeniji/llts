# `std/debug`

The `debug` module provides essential utilities for logging, formatted output, and condition assertions in LLTS. It interfaces directly with native VM built-ins to deliver efficient host-level logging and standard output handling.

## Overview

```llts
const debug = @import("std/debug");

// Formatted printing
debug.printLn("Hello, {s}! Your score is {i}.", "Alice", 100, null, null);

// Host logging
debug.info("Application started.");
debug.warn("Disk space is running low.");

// Assertions
debug.assert(score >= 0);
```

## Functions

### `printLn(msg, a, b, c, d)`
Prints a formatted string to standard output, followed by a newline.

It relies on the `__printLn` native function, which iterates through the string and replaces format placeholders with the provided arguments in order.

**Format Specifiers:**
- `{s}`: Used for inserting string values.
- `{i}`: Used for inserting integer, boolean, null, or pointer values.

**Example:**
```llts
debug.printLn("Status: {s}, Retries left: {i}", "Connecting", 3, null, null);
```
*Note: Due to current language arity constraints, `printLn` accepts exactly a format message and 4 substitution arguments. Pass `null` for unused arguments if your format string has fewer than 4 placeholders.*

---

### `log(msg)`
An alias for `info(msg)`. Logs a message at the `info` severity level.

---

### `trace(msg)`
Logs a message at the `trace` severity level. This is handled natively by the host environment logger.

---

### `debug(msg)`
Logs a message at the `debug` severity level.

---

### `info(msg)`
Logs a message at the `info` severity level.

---

### `warn(msg)`
Logs a message at the `warn` severity level.

---

### `err(msg)`
Logs a message at the `error` severity level.

**Special Behavior:** 
If the `msg` argument passed to `err()` is an LLTS error value, the native logging implementation (`__hostLog`) will automatically detect it. It cleanly formats the error code and its payload without emitting a redundant `"Error: "` prefix in the logs, making structured error logs much more readable.

**Example:**
```llts
const result = someOperation();
@if (isError(result)) {
    debug.err(result);
}
```

---

### `assert(condition)`
Asserts that the provided `condition` is truthy.

**Returns:** 
- `null` if the condition is true.
- `error("AssertFailed", condition)` if the condition evaluates to false, passing the falsy condition value as the error payload.

**Example:**
```llts
const err = debug.assert(user_id > 0);
@if (isError(err)) {
    debug.err(err);
    return err;
}
```
