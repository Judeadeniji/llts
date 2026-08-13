# Standard Library (std)

The `llts-zig` standard library provides a rich set of built-in modules to help you write powerful programs. 

Here is a list of the available standard library modules:

* [buffer](buffer.md) - Binary buffer manipulation and operations.
* [debug](debug.md) - Diagnostic tools, structured logging, and assertions.
* [fs](fs.md) - File system operations and path manipulation.
* [http](http.md) - HTTP client operations.
* [io](io.md) - Standard input and output operations.
* [json](json.md) - JSON parsing and serialization.
* [list](list.md) - Dynamic array structures and manipulation.
* [map](map.md) - Hash map structures and manipulation.
* [math](math.md) - Mathematical constants and functions.
* [mem](mem.md) - Memory inspection and manipulation.
* [os](os.md) - Operating system level interactions.
* [syscall](syscall.md) - Low-level Linux/POSIX syscalls and constants.
* [string](string.md) - String manipulation and operations.
* [time](time.md) - Date, time, and timing operations.

To use any of these modules, import them using the `@import` keyword:

```
const $math = @import("std/math");
const $debug = @import("std/debug");

$debug.info("Pi is roughly {}", [$math.pi]);
```
