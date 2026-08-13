# Syscall (`std/syscall`)

Low-level operating system traps, Linux-oriented. Prefer typed wrappers (`read`, `write`, `open`, …). Use raw `call` + `SYS_*` only when you need a direct kernel trap.

`std/os` and `std/fs` stay the high-level APIs; this module is the escape hatch underneath them.

## Raw interface

### `call(nr, ...args) -> int`
Invoke syscall number `nr` with up to six integer arguments. Returns the kernel result as a signed integer (Linux convention: `-1..-4095` means `-errno`).

```llts
@const $syscall = @import("std/syscall");
$pid = syscall.call(syscall.SYS_getpid);
```

### `nr(name: string) -> int | SyscallError`
Look up a `SYS_*` number by name for the host architecture (e.g. `"openat"`, `"clock_gettime"`).

### `isError(rc) -> bool` / `errno(rc) -> int` / `errName(rc) -> string`
Decode a raw `call` result. `errName` returns `""` on success, otherwise a Linux `E.*` tag such as `"NOENT"`.

## Typed wrappers

These use the host POSIX layer, return values or a `SyscallError` (`.code == "SyscallError"`, `.payload` is a short reason / errno name).

| Function | Notes |
|---|---|
| `read(fd, buf)` | `buf` is a `std/buffer`; returns bytes read |
| `write(fd, data)` | `data` is a string or buffer; returns bytes written |
| `open(path, flags, ...mode)` | mode defaults to `0` |
| `close(fd)` | |
| `lseek(fd, offset, whence)` | returns new offset |
| `fsync(fd)` | |
| `pipe()` | returns `[read_fd, write_fd]` |
| `dup(fd)` / `dup2(old, new)` | |
| `getpid` / `getppid` / `getuid` / `geteuid` / `getgid` / `getegid` | |
| `kill(pid, sig)` | |
| `chdir(path)` / `getcwd()` | |
| `unlink` / `rename` / `mkdir` / `rmdir` | `mkdir` mode defaults to `0o755` |
| `access(path, ...mode)` | mode defaults to `F_OK` |
| `chmod` / `symlink` / `readlink` | |
| `ftruncate(fd, len)` / `umask(mask)` | |
| `nanosleep(sec, nsec)` | |
| `fcntl(fd, cmd, ...arg)` | |

### Example — write a file

```llts
@const $syscall = @import("std/syscall");
@const $buffer = @import("std/buffer");

$flags = syscall.O_CREAT | syscall.O_WRONLY | syscall.O_TRUNC;
$fd = syscall.open("/tmp/out.txt", flags, 0o644);
syscall.write(fd, "hello\n");
syscall.close(fd);

$fd = syscall.open("/tmp/out.txt", syscall.O_RDONLY);
$buf = buffer.alloc(64);
$n = syscall.read(fd, buf);
syscall.close(fd);
```

## Constants

Host-injected (arch-correct on Linux):

- **SYS_*** — `SYS_read`, `SYS_write`, `SYS_open`, `SYS_openat`, `SYS_close`, `SYS_getpid`, …
- **O_*** — `O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_CREAT`, `O_EXCL`, `O_TRUNC`, `O_APPEND`, `O_NONBLOCK`, `O_DIRECTORY`, `O_CLOEXEC`
- **SEEK_*** — `SEEK_SET`, `SEEK_CUR`, `SEEK_END`
- **stdio** — `STDIN_FILENO`, `STDOUT_FILENO`, `STDERR_FILENO`
- **access** — `F_OK`, `R_OK`, `W_OK`, `X_OK`
- **mode** — `S_IRUSR`, `S_IWUSR`, … / `S_IRWXU`, …
- **signals** — `SIGTERM`, `SIGKILL`, `SIGINT`, `SIGHUP`, `SIGUSR1`, `SIGUSR2`
- **fcntl** — `F_GETFD`, `F_SETFD`, `F_GETFL`, `F_SETFL`, `FD_CLOEXEC`
- **AT_FDCWD**

> Flag combination: use bitwise `|` (e.g. `O_CREAT | O_WRONLY | O_TRUNC`). `^` is still exponentiation — XOR is `~` as a binary operator.
