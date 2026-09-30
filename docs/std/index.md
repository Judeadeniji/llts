# Standard Library (std)

The `llts-zig` standard library provides a rich set of built-in modules to help you write powerful programs. 

Here is a list of the available standard library modules:

* [buffer](buffer.md) - Binary buffer manipulation and operations.
* [fmt](fmt.md) - Formatted I/O Analogous to Go's `fmt` (printf, sprintf, verbs, flags).
* [fs](fs.md) - File system operations and path manipulation.
* [http](http.md) - HTTP client operations.
* [io](io.md) - Standard input and output operations.
* [json](json.md) - JSON parsing and serialization.
* [list](list.md) - Dynamic array structures and manipulation.
* [log](log.md) - Standard logging analogous to Go's `log` package.
* [map](map.md) - Hash map structures and manipulation.
* [math](math.md) - Mathematical constants and functions.
* [mem](mem.md) - Memory inspection and manipulation.
* [os](os.md) - Operating system level interactions.
* [slog](slog.md) - Structured leveled logging analogous to Go's `slog` package.
* [syscall](syscall.md) - Low-level Linux/POSIX syscalls and constants.
* [string](string.md) - String manipulation and operations.
* [time](time.md) - Date, time, and timing operations.

To use any of these modules, import them using the `@import` keyword:

```llts
@const $fmt = @import("std/fmt");
@const $slog = @import("std/slog");

fmt.printf("Pi is roughly %.4f\n", 3.14159);
slog.info("Application initialized", "version", "1.0.0");
```
