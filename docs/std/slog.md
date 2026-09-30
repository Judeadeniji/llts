# `std/slog`

The `std/slog` package implements structured logging with severity levels and key-value attributes, analogous to Go's `log/slog` package.

## Overview

```llts
@const $slog = @import("std/slog");

// Basic leveled logging
slog.info("Server started", "port", 8080, "env", "production");
slog.warn("Database connection pool high", "active", 45, "max", 50);

// Error values are automatically formatted with code and payload
slog.err(error("FileNotFound", "config.json"));

// Child loggers with persistent context attributes
$reqLogger = slog.with("request_id", "req-1234");
reqLogger.info("Processing order", "order_id", 992);
```

## Levels

* `LevelDebug = -4`: Informational events useful during development and debugging.
* `LevelInfo = 0`: Normal, operational events.
* `LevelWarn = 4`: Non-critical warnings.
* `LevelError = 8`: Critical failure events.

The host logger sink automatically respects the `LLTS_LOG_LEVEL` environment variable (`trace`, `debug`, `info`, `warn`, `error`) and provides ANSI colored severity tags.

## Functions

### `debug(msg, ...keyValues)`
Logs a message at `debug` severity, optionally followed by alternating key-value pairs.

### `info(msg, ...keyValues)`
Logs a message at `info` severity, optionally followed by alternating key-value pairs.

### `warn(msg, ...keyValues)`
Logs a message at `warn` severity, optionally followed by alternating key-value pairs.

### `error(msg, ...keyValues)` / `err(msg, ...keyValues)`
Logs a message at `error` severity. When passed an LLTS error object, automatically extracts and displays the error code and payload.

### `log(level: int, msg, ...keyValues)`
Logs a message at the specified integer severity level.

### `with(...keyValues): Logger`
Creates a child `Logger` that includes the specified key-value attributes on every subsequent log call.

### `assert(condition)`
Condition assertion utility. Returns `null` if the condition is truthy, or returns `error("AssertFailed", condition)` if false.
