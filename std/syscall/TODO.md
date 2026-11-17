# Syscall library roadmap

Inventory of the syscall-backed functions glibc exposes, grouped by area, with
the planned location in the library and current status. The list was derived
from the glibc headers on the supported Linux x86-64 target (`unistd.h`,
`fcntl.h`, `sys/stat.h`, `sys/mman.h`, `sys/wait.h`, `signal.h`, `time.h`,
`sys/socket.h`, `sys/uio.h`, `dirent.h`, `termios.h`, `pwd.h`, `grp.h`,
`sched.h`, `sys/epoll.h`, `sys/inotify.h`, `sys/timerfd.h`, `sys/xattr.h`, and
related headers under `/usr/include`).

Legend:

- `[x]` implemented and covered by a native test.
- `[ ]` implementable with the current language and runtime.
- `[!]` blocked by a compiler or language gap; see [Blockers](#blockers).

The `*64`, `*_time64`, and `__*` alias symbols are not listed separately; they
are ABI aliases of the canonical entry on LP64, not additional APIs.

## Current state

Everything currently public lives in `std/syscall.lls`, with raw externs in
`std/syscall/c.lls`.

- `[x]` `Fd` and `Pid` nominal types.
- `[x]` enums: `Stdio`, `Access`, `OpenFlag`, `Permission`, `SeekWhence`, `ExitCode`.
- `[x]` closed `SyscallError` set and `errno` mapping.
- `[x]` `STDIN`, `STDOUT`, `STDERR` constants.
- `[x]` `exit`, `abort` (`never`), `process_id`.
- `[x]` `read`, `write`, `write_all`, `is_terminal`, `seek`, `truncate_file`.
- `[x]` `open_read`, `open_write`, `open_append`, `create` (plus private
  `open_with`), `close`, `unlink`.

## Planned layout

Keep related calls together; one module per area rather than one file per call.
`std/syscall.lls` remains the facade.

| File | Contents |
|---|---|
| `std/syscall.lls` | Public facade, shared types, enums, errors, stdio constants |
| `std/syscall/c.lls` | Raw externs and C ABI helpers (internal) |
| `std/syscall/io.lls` | Descriptors, open flags, read/write/seek, dup, sync, truncate, pipe |
| `std/syscall/stat.lls` | `stat` family, permissions, ownership, timestamps |
| `std/syscall/dir.lls` | `mkdir`, directory iteration, cwd |
| `std/syscall/process.lls` | Identity, fork/exec/wait, sessions, priority |
| `std/syscall/signal.lls` | Signal sets, masking, sending, handlers |
| `std/syscall/time.lls` | Clocks, sleeps, interval timers |
| `std/syscall/memory.lls` | `mmap` family, locking, page queries |
| `std/syscall/socket.lls` | Sockets, addresses, send/recv, options |
| `std/syscall/poll.lls` | `select`, `poll`, `epoll` readiness |
| `std/syscall/event.lls` | `eventfd`, `timerfd`, `inotify`, `fanotify`, `signalfd` |
| `std/syscall/user.lls` | passwd and group database calls |
| `std/syscall/term.lls` | Terminal attributes and control |
| `std/syscall/system.lls` | `uname`, `sysconf`, rlimits, scheduling, mounts |
| `std/syscall/ipc.lls` | System V shared memory, semaphores, message queues |
| `std/syscall/xattr.lls` | Extended attributes |

Module re-export is not available today: `pub @const $m = @import("./m.lls")`
inside a module does not expose `m` to importers. Until the compiler supports
it, an area module is either imported directly by path or its public
functions are re-declared as thin wrappers in the facade.

## Blockers

These are compiler/language issues, not library design choices. They decide
which entries below are marked `[!]`.

1. **[RESOLVED] C struct layout.** Added `@extern "c" @struct` support.
   Native emitter renders as Zig `extern struct` preserving declaration order and C ABI layout.
2. **[RESOLVED] `@sizeOf` disagrees with the backend.** Compiler layout calculates exact C ABI
   size and alignment, and `@sizeOf` / `@alignOf` match native Zig `extern struct` sizes.
3. **Function pointers rejected in extern signatures.** `@func(...)` works as a
   value type, but extern parameters only accept scalars, `c_str`, and pointers,
   so callbacks (`signal`, `sigaction`, `atexit`, `scandir`, `timer_create`)
   still need compiler support.
4. **No double indirection (`**T`).** Blocks `exec*` argument vectors,
   `getaddrinfo`, `posix_memalign`, and any C API that allocates through an
   out-pointer.
5. **[RESOLVED] Scalar pointers (`*i32`).** Scalar pointers work in extern
   signatures and expressions; the `IntCell`/`IdCell` wrapper structs remain as
   harmless ABI helpers.
6. **No pointer arithmetic or pointer casts.** Blocks generic `sockaddr`
   handling, walking `dirent` buffers, and returning borrowed C memory as
   slices.
7. **No C-to-LLTS string conversion.** An extern can accept `c_str` and string
   literals, but a `char *` returned by libc can't be turned into a `string`
   without a runtime helper (`getenv`, `getcwd`, `realpath`, `ttyname`,
   `readlink`).
8. **Struct arrays in literals.** Array fields can only be initialized from a
   named temporary today; inline `[N]u8{...}` is rejected. This is an
   ergonomics issue once blocker 1 is fixed.
9. **Variadic externs.** True varargs are supported and used by `ioctl` and
   `syscall`; fixed-arity entry points (`open`, `fcntl`, `prctl`) are still
   declared with their concrete trailing parameters.
10. **Resolved enum members and imported extern types** were fixed on this
    branch and are prerequisites for the modules above.

## Descriptors and basic I/O (`io.lls`)

- `[x]` `read`
- `[x]` `write`
- `[x]` `write_all` (library helper)
- `[x]` `close`
- `[x]` `seek` (`lseek`)
- `[x]` `ftruncate` as `truncate_file`
- `[x]` `pread`, `pwrite`
- `[x]` `readv`, `writev`, `preadv`, `pwritev`, `preadv2`, `pwritev2`
- `[x]` `truncate`
- `[x]` `fsync`, `fdatasync`, `sync`, `syncfs`
- `[x]` `dup`, `dup2`, `dup3`
- `[x]` `pipe`, `pipe2`
- `[x]` `sendfile`, `copy_file_range`
- `[x]` `fallocate`, `posix_fallocate`, `posix_fadvise`
- `[x]` `close_range`, `closefrom`
- `[x]` `fcntl` (`F_GETFD`, `F_SETFD`, `F_GETFL`, `F_SETFL`, `F_DUPFD`,
  `F_DUPFD_CLOEXEC`, `F_GETPIPE_SZ`, `F_SETPIPE_SZ`; record locks are under
  locking)
- `[x]` `ioctl` (variadic extern; typed wrappers for `TIOCGWINSZ`,
  `TIOCSWINSZ`, `FIONREAD`)
- `[x]` `getdtablesize` (as `descriptor_table_size`)
- `[x]` `vhangup`, `revoke`, `profil`

## Opening and creation (`io.lls`)

- `[x]` `open_read`, `open_write`, `open_append`, `create`
- `[x]` general `open(path, flags, mode)`
- `[x]` `openat` (with `AT_FDCWD`)
- `[x]` `creat`
- `[x]` `open64`, `openat64` (alias; no separate wrapper)
- `[!]` `mkstemp`, `mkostemp`, `mkdtemp` (libc helpers over `open`/`mkdir`; blocker 7)
- `[x]` `shm_open`, `shm_unlink`

## File metadata (`stat.lls`)

- `[x]` `stat`, `fstat`, `lstat`, `fstatat`
- `[x]` `statfs`, `fstatfs`, `statvfs`, `fstatvfs`
- `[x]` `chmod`, `fchmod`, `fchmodat`
- `[x]` `umask`, `getumask`
- `[x]` `chown`, `fchown`, `lchown`, `fchownat`
- `[x]` `utimensat`, `futimens`
- `[x]` `mknod`, `mknodat`, `mkfifo`, `mkfifoat`
- `[!]` `readlink`, `readlinkat` (also blocker 7)

## Paths, links and permissions (`dir.lls`)

- `[x]` `unlink`
- `[x]` `unlinkat`, `rmdir`
- `[x]` `link`, `linkat`, `symlink`, `symlinkat`
- `[x]` `rename`, `renameat` (`renameat2` is raw-only)
- `[x]` `mkdir`, `mkdirat`
- `[x]` `chdir`, `fchdir`
- `[!]` `getcwd`, `getwd`, `get_current_dir_name` (blocker 7)
- `[x]` `chroot`
- `[x]` `access`, `faccessat`, `eaccess`, `euidaccess`
- `[!]` `realpath` (blocker 7)

## Directories (`dir.lls`)

- `[x]` `opendir`, `fdopendir`, `closedir`, `readdir` (`readdir_r` omitted:
  deprecated by glibc)
- `[x]` `rewinddir`, `seekdir`, `telldir`, `dirfd`
- `[!]` `scandir`, `scandirat`, `alphasort`, `versionsort` (callbacks)
- `[x]` `getdirentries` (glibc wrapper; raw `getdents64` also available via
  the syscall escape hatch)

## Process identity and control (`process.lls`)

- `[x]` `getpid` as `process_id`
- `[x]` `exit`, `abort`
- `[x]` `getppid`
- `[x]` `getuid`, `geteuid`, `getgid`, `getegid`
- `[x]` `setuid`, `seteuid`, `setgid`, `setegid`
- `[x]` `setreuid`, `setregid`, `setresuid`, `setresgid`
- `[x]` `getresuid`, `getresgid`
- `[x]` `getgroups`, `setgroups`, `initgroups`, `getgrouplist`
- `[x]` `getsid`, `setsid`, `getpgid`, `setpgid`, `getpgrp`, `setpgrp`
- `[!]` `getlogin`, `getlogin_r` (blocker 7)
- `[x]` `daemon`
- `[ ]` `_exit` is not planned; `exit` is the public path

## Process creation and exec (`process.lls`)

- `[x]` `fork` (`vfork` omitted: unsafe with runtime allocator/stdio)
- `[!]` `execv`, `execvp`, `execvpe`, `execve`, `execveat`, `fexecve`,
  `execl`, `execle`, `execlp` (blocker 4; `execl*` additionally need sentinel
  varargs)
- `[!]` `posix_spawn`, `posix_spawnp` (callback/attr structs)
- `[x]` `wait`, `waitpid` (status inspectable via `wait_status`, `wifexited`, `wexitstatus`, etc.)
- `[x]` `pause`
- `[x]` `sleep`, `usleep`, `alarm`
- `[x]` `sched_yield`

## Signals (`signal.lls`)

- `[!]` `signal`, `sigaction`, `bsd_signal`, `sysv_signal`, `ssignal`,
  `gsignal`, `siginterrupt`, `sigset`, `sighold`, `sigrelse`, `sigignore`,
  `sigpause`, `sigstack` (callbacks or legacy C-only interfaces)
- `[x]` `kill`, `killpg`, `raise`
- `[x]` `sigqueue` (`union sigval` passed as its pointer-sized `i64` payload)
- `[x]` `sigemptyset`, `sigfillset`, `sigaddset`, `sigdelset`,
  `sigismember`, `sigandset`, `sigorset`, `sigisemptyset` (explicit `SigSet`
  bitset type with `sigset_*` helpers)
- `[x]` `sigprocmask`, `sigpending`, `sigsuspend`, `sigwait`, `sigwaitinfo`,
  `sigtimedwait`
- `[x]` `sigaltstack`
- `[x]` `psignal`, `psiginfo`
- `[ ]` `sigreturn` (raw only; not useful from a libc wrapper)
- `[!]` `signalfd` (struct layout plus a readable fd type)

## Time and timers (`time.lls`)

- `[x]` `time`
- `[x]` `clock_gettime`, `clock_settime`, `clock_getres`, `clock_nanosleep`, `nanosleep`
- `[x]` `clock_getcpuclockid`
- `[!]` `getitimer`, `setitimer`
- `[!]` `timer_create`, `timer_delete`, `timer_settime`, `timer_gettime`,
  `timer_getoverrun` (callback in `sigevent`)
- `[x]` `adjtime`
- `[x]` `mktime`, `timegm`, `timelocal`, `difftime`, `tzset` (libc date math)
- `[!]` `strftime`, `strptime`, `localtime`, `gmtime`, `ctime`, `asctime`
  (formatting/locale, out of scope for the syscall layer)

## Memory (`memory.lls`)

- `[x]` `mmap`, `munmap`, `mprotect`, `mremap`, `msync`
- `[x]` `madvise`, `posix_madvise`
- `[x]` `mlock`, `munlock`, `mlockall`, `munlockall`
- `[x]` `brk`, `sbrk` (legacy, exported for completeness)
- `[x]` `getpagesize`, `sysconf(_SC_PAGESIZE)`
- `[!]` `posix_memalign` (blocker 4)
- `[x]` `memfd_create`
- `[x]` `shm_open`, `shm_unlink` (also listed under opening)

## Pipes and vector I/O (`io.lls`)

- `[x]` `pipe`, `pipe2` (pass a pointer to a struct / PipeFds)
- `[x]` `dup`, `dup2`, `dup3`

## Sockets (`socket.lls`)

- `[x]` `socket`
- `[ ]` `socketpair`
- `[x]` `bind`, `connect`, `listen`, `accept`, `shutdown`
- `[ ]` `accept4`, `sendto`, `recvfrom`
- `[x]` `send`, `recv`
- `[ ]` `sendmsg`, `recvmsg`, `sendmmsg`, `recvmmsg` (`msghdr` layout)
- `[x]` `getsockname`, `getpeername`
- `[ ]` `getsockopt`, `setsockopt`
- `[ ]` `sockatmark`, `isfdtype`
- `[!]` `getaddrinfo`, `freeaddrinfo`, `getnameinfo`, `gai_strerror`
  (blocker 4; libc resolver, not a direct syscall)

Planned typed surface: `RequestedAddressFamily` (`Inet`, `Inet6`, `Unix`),
`SocketKind` (`Stream`, `Datagram`, `SequentialPacket`), `Address` as a
nominal struct with constructors rather than a raw `sockaddr`, and
`set_option`/`get_option` enums for common `SOL_SOCKET`/`IPPROTO_TCP` options.

## Readiness and polling (`poll.lls`)

- `[ ]` `select`, `pselect` (`fd_set` is a fixed bitset, now expressible)
- `[x]` `poll` (with `poll_one` and slice `poll`; `pollfd` layout)
- `[ ]` `ppoll` (`pollfd` layout and `SigSet` are now available)
- `[!]` `epoll_create`, `epoll_create1`, `epoll_ctl`, `epoll_wait`,
  `epoll_pwait`, `epoll_pwait2` (event struct layout)

## Event, timer and notification descriptors (`event.lls`)

- `[x]` `eventfd`, `eventfd_read`, `eventfd_write`
- `[!]` `timerfd_create`, `timerfd_gettime`, `timerfd_settime`
- `[!]` `inotify_init`, `inotify_init1`, `inotify_add_watch`,
  `inotify_rm_watch` (path conversion is fine; event struct layout is not)
- `[!]` `fanotify_init`, `fanotify_mark`
- `[!]` `signalfd`

## Users and groups (`user.lls`)

All `[!]` on `struct passwd`/`struct group` layout; the `_r` variants also
need caller buffers and `**` out-pointers.

- `[!]` `getpwnam`, `getpwuid`, `getpwent`, `fgetpwent`
- `[!]` `getpwnam_r`, `getpwuid_r`, `getpwent_r`, `fgetpwent_r`
- `[!]` `setpwent`, `endpwent`, `putpwent`
- `[!]` `getgrnam`, `getgrgid`, `getgrent`, `fgetgrent`
- `[!]` `getgrnam_r`, `getgrgid_r`, `getgrent_r`, `fgetgrent_r`
- `[!]` `setgrent`, `endgrent`, `putgrent`

## Terminals (`term.lls`)

- `[x]` `isatty` as `is_terminal`
- `[x]` `tcgetattr`, `tcsetattr` (`termios` layout)
- `[ ]` `cfmakeraw`, `cfgetispeed`, `cfsetispeed`, `cfgetospeed`, `cfsetospeed`, `cfsetspeed`
- `[x]` `tcgetpgrp`, `tcsetpgrp`, `tcgetsid`, `tcdrain`, `tcflow`, `tcflush`,
  `tcsendbreak`
- `[!]` `ttyname`, `ttyname_r`, `ctermid`, `ttyslot` (string conversion)

## System information (`system.lls`)

- `[!]` `uname` (`utsname` layout)
- `[!]` `gethostname`, `sethostname`, `getdomainname`, `setdomainname`
  (fixed char arrays plus string conversion)
- `[x]` `sysconf`, `pathconf`, `fpathconf`
- `[x]` `getauxval`
- `[!]` `sysinfo` (struct layout)
- `[x]` `get_nprocs`, `get_nprocs_conf`, `get_phys_pages`, `get_avphys_pages`
- `[x]` `gethostid`
- `[x]` `personality`
- `[x]` `prctl`
- `[x]` `getrandom`
- `[x]` `memfd_create`

## Resources, scheduling and priority (`system.lls`)

- `[x]` `getrlimit`, `setrlimit`, `prlimit` (`rlimit` layout)
- `[!]` `getrusage` (struct layout)
- `[x]` `getpriority`, `setpriority`, `nice`
- `[x]` `sched_get_priority_max`, `sched_get_priority_min`, `sched_yield`
- `[!]` `sched_getparam`, `sched_setparam`, `sched_getscheduler`,
  `sched_setscheduler`, `sched_rr_get_interval` (struct layout)
- `[!]` `sched_getaffinity`, `sched_setaffinity` (`cpu_set_t` layout)

## Advisory locking (`io.lls`)

- `[x]` `flock`
- `[!]` `fcntl` record locks (`F_GETLK`, `F_SETLK`, `F_SETLKW`; `struct flock`
  layout)
- `[!]` `lockf` (same `struct flock` requirement)

## System V IPC (`ipc.lls`)

- `[!]` `shmget`, `shmat`, `shmdt`, `shmctl` (struct layout; `shmat` returns
  an address)
- `[!]` `semget`, `semop`, `semtimedop`, `semctl` (`union semun` needs
  explicit per-command wrappers)
- `[!]` `msgget`, `msgsnd`, `msgrcv`, `msgctl` (struct layout)
- `[x]` `ftok`

Prefer `shm_open`/`mmap` for new code; System V IPC is completeness only.

## Extended attributes (`xattr.lls`)

All `[!]` until string conversion and layout/casting rules are settled; the
value buffers themselves can be slices.

- `[!]` `getxattr`, `lgetxattr`, `fgetxattr`
- `[!]` `setxattr`, `lsetxattr`, `fsetxattr`
- `[!]` `listxattr`, `llistxattr`, `flistxattr`
- `[!]` `removexattr`, `lremovexattr`, `fremovexattr`

## Mounts, swap and kernel control (`system.lls`)

Privileged operations; keep them in one submodule with explicit
`CapabilityRequired` documentation.

- `[!]` `mount`, `umount`, `umount2`, `mount_setattr`
- `[!]` `open_tree`, `move_mount`, `fsopen`, `fsconfig`, `fsmount`, `fspick`
- `[x]` `swapon`, `swapoff`
- `[x]` `reboot`
- `[x]` `klogctl`
- `[x]` `acct`

## Raw escape hatch (`std/syscall.lls`)

- `[x]` `syscall(number, ...)` behind a nominal `SyscallNumber` struct, with
  `syscall0`…`syscall5` arity helpers and `SYS_*` constants, so unwrapped
  Linux entry points are still reachable without importing libc.
- Not every one of the 384 entries in `asm/unistd_64.h` has a glibc wrapper;
  `syscall` is the only way to reach the rest from this library.

## Out of scope

These are libc services rather than syscall wrappers; they belong in other
stdlib modules:

- stdio (`printf`, `fopen`, `fread`, `FILE*`), already served by `rt.print`
- allocator (`malloc`, `free`, `calloc`, `realloc`, `aligned_alloc`)
- string/memory routines (`memcpy`, `strlen`, `strcmp`, `strdup`, ...)
- formatting, locale, iconv, regex
- dynamic loading (`dlopen`, `dlsym`, `dlclose`)
- DNS/service lookup beyond the socket layer (`getaddrinfo` is listed above
  because networking needs it)
- math, random, hashing

## Suggested order

1. Unblock C layout (blocker 1) and add `@sizeOf` agreement (blocker 2); this
   unlocks stat, time, polling, sockets, terminals, users, resources.
2. `io.lls`: `pread`/`pwrite`, `ftruncate`, `fsync`, `dup`, `pipe`, `fcntl`
   basics, `mkdir`/`rmdir`/`rename`/`link`, `chdir`/`getcwd`.
3. `time.lls` with `time`, `clock_gettime`, `nanosleep`.
4. `process.lls`: identity, `waitpid`, `getrlimit`, `sysconf`.
5. `signal.lls`: sets, mask, `kill`, `raise` (handlers wait on callbacks).
6. `poll.lls` and `socket.lls`; then `event.lls`.
7. Completeness passes: `user.lls`, `term.lls`, `ipc.lls`, `xattr.lls`,
   privileged mounts.
