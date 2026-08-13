# `std/io`

Standard streams and byte I/O. Path-based files live in [`std/fs`](fs.md).

## Streams

```llts
@const $io = @import("std/io");

io.stdout.writeAll("hello\n");
io.eprint("oops\n");
$line = io.stdin.readLine(); # null on EOF
```

| Export | Value |
|---|---|
| `io.stdin` / `stdout` / `stderr` | `File` handles for fds 0 / 1 / 2 |
| `io.fromFd(fd)` | wrap any fd as a `File` |

Do **not** `syscall.close` the standard streams.

## `File` methods

| Method | Notes |
|---|---|
| `write(data)` | One `write(2)`; may be short. String or buffer. |
| `writeAll(data)` | Loops until all bytes are written. |
| `read(buf)` | Into a `std/buffer`; returns byte count (`0` = EOF). |
| `readLine()` | Up to a newline (or one chunk); `null` on EOF. |
| `flush()` | `fsync` on the fd. |

## Fd operations

Same helpers take a raw fd (useful for pipes):

| Function | Notes |
|---|---|
| `write(fd, data)` / `writeAll(fd, data)` | |
| `read(fd, buf)` / `readLineFd(fd)` | |

```llts
$fds = syscall.pipe();
io.writeAll(fds[1], "ping");
# or:
$w = io.fromFd(fds[1]);
w.writeAll("ping");
```

## Convenience

| Function | Behavior |
|---|---|
| `readLine()` | `stdin.readLine()` |
| `print` / `println` | write / write+`\\n` on stdout |
| `eprint` / `eprintln` | same on stderr |
| `readAll()` | drain stdin to EOF into a string |

## Example

```llts
@const $io = @import("std/io");

@func main() {
    io.println("What is your name?");
    $name = io.readLine();
    @if (name == null) {
        io.eprintln("EOF");
        return;
    }
    io.print("Hello, ");
    io.print(name);
    io.print("\n");
}
```
