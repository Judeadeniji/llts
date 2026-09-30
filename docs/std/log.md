# `std/log`

The `std/log` package implements standard logging analogous to Go's `log` package. It provides output formatting to standard error (or any file descriptor) with customizable headers and fatal/panic exit handlers.

## Overview

```llts
@const $log = @import("std/log");

log.println("Application starting...");
log.printf("Listening on port %d", 8080);

// Fatal exits the process with code 1 after logging
// log.fatal("Unrecoverable error occurred");
```

## Flags

* `Ldate`: The date in the local time zone (`2009/01/23`).
* `Ltime`: The time in the local time zone (`01:23:23`).
* `Lmicroseconds`: Microsecond resolution (`01:23:23.123123`).
* `LstdFlags`: Default flags (`Ldate | Ltime`).
* `Lmsgprefix`: Place the prefix immediately before the message rather than at line start.

## Functions

### `print(...args)`
Prints formatted operands using default `%v` format to standard error with the logger's header.

### `printf(format, ...args)`
Prints formatted output according to format verbs to standard error with the logger's header.

### `println(...args)`
Prints space-separated operands followed by a newline to standard error with the logger's header.

### `fatal(...args)`
Logs using `print` and immediately terminates the process with exit code 1.

### `fatalf(format, ...args)`
Logs using `printf` and immediately terminates the process with exit code 1.

### `fatalln(...args)`
Logs using `println` and immediately terminates the process with exit code 1.

### `panic(...args)` / `panicf(format, ...args)` / `panicln(...args)`
Logs the formatted message and halts execution.

### `setPrefix(prefix: string)` / `prefix(): string`
Configures the logger prefix string prepended to each line.

### `setFlags(flag: int)` / `flags(): int`
Configures the logger flags controlling timestamp and file headers.

### `setOutput(fd: int)`
Sets the destination file descriptor for output (defaults to stderr / 2).

### `new(out: int, prefix: string, flag: int): Logger`
Creates an independent `Logger` instance writing to `out`.
