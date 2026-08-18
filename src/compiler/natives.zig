//! Native signature table for the LLVM backend.
//!
//! The std/`.lls` modules are thin wrappers around `__`-prefixed native
//! functions (`__strlen`, `__floor`, ...). In the bytecode VM those natives
//! are implemented in `src/vm/builtins/*` and take packed `Value` handles.
//! Natively they are plain C-ABI functions with simple scalar types, so the
//! compiler needs a signature table to:
//!
//!   1. type native *call sites* in the typechecker (`.func` types with real
//!      param/return types instead of `TUnknown`), which in turn lets
//!      unannotated std wrappers infer their return types, and
//!   2. declare the natives with real LLVM signatures in the backend instead
//!      of variadic `i64` stubs.
//!
//! Type names are display strings understood by both the typechecker
//! (`parseDisplayType`) and the LLVM backend (`types.zig::resolve`):
//! `int`, `float`, `bool`, `string`, `[]string`, `unknown`.
//!
//! Runtime implementations live in `src/runtime/natives.zig` and are linked
//! by `scripts/emit-run.sh`.

const std = @import("std");

pub const NativeSig = struct {
    name: []const u8,
    params: []const []const u8,
    ret: []const u8,
    /// True for natives whose LLS callers pass a variable number of trailing
    /// args (`__sys_open(path, flags)` or `__sys_open(path, flags, mode)`).
    /// The typechecker seeds them as variadic func types (lenient arity) and
    /// the backend declares the FULL param list, zero-padding missing args.
    variadic: bool = false,
};

pub const signatures = [_]NativeSig{
    // ── len (special-cased in the backend: arrays → constant, strings → __strlen) ──
    .{ .name = "len", .params = &.{"unknown"}, .ret = "int" },

    // ── string module (std/string.lls) ──
    .{ .name = "__strlen", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__substr", .params = &.{ "string", "int", "int" }, .ret = "string" },
    .{ .name = "__indexOf", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__split", .params = &.{ "string", "string" }, .ret = "[]string" },
    .{ .name = "__toUpper", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__toLower", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__trim", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__replace", .params = &.{ "string", "string", "string" }, .ret = "string" },
    .{ .name = "__concat", .params = &.{ "string", "string" }, .ret = "string" },
    .{ .name = "__repeat", .params = &.{ "string", "int" }, .ret = "string" },
    .{ .name = "__startsWith", .params = &.{ "string", "string" }, .ret = "bool" },
    .{ .name = "__endsWith", .params = &.{ "string", "string" }, .ret = "bool" },
    .{ .name = "__charCodeAt", .params = &.{ "string", "int" }, .ret = "int" },
    .{ .name = "__parseInt", .params = &.{ "string", "int" }, .ret = "int" },
    .{ .name = "__parseFloat", .params = &.{"string"}, .ret = "float" },
    .{ .name = "__fromCharCode", .params = &.{"int"}, .ret = "string" },
    .{ .name = "__contains", .params = &.{ "string", "string" }, .ret = "bool" },
    .{ .name = "__lastIndexOf", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__indexOfFrom", .params = &.{ "string", "string", "int" }, .ret = "int" },
    .{ .name = "__trimStart", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__trimEnd", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__replaceFirst", .params = &.{ "string", "string", "string" }, .ret = "string" },
    .{ .name = "__slice", .params = &.{ "string", "int", "int" }, .ret = "string" },
    .{ .name = "__compare", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__eql", .params = &.{ "string", "string" }, .ret = "bool" },
    .{ .name = "__splitMax", .params = &.{ "string", "string", "int" }, .ret = "[]string" },
    .{ .name = "__join", .params = &.{ "[]string", "string" }, .ret = "string" },
    .{ .name = "__padStart", .params = &.{ "string", "int", "string" }, .ret = "string" },
    .{ .name = "__padEnd", .params = &.{ "string", "int", "string" }, .ret = "string" },
    .{ .name = "__isEmpty", .params = &.{"string"}, .ret = "bool" },
    .{ .name = "__isBlank", .params = &.{"string"}, .ret = "bool" },

    // ── math module (std/math.lls) ──
    // Integer-returning (VM converts the f64 result via @intFromFloat).
    .{ .name = "__floor", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__ceil", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__round", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__sqrt", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__pow", .params = &.{ "float", "float" }, .ret = "int" },
    // min/max receive the rest-args array (count-prefixed, `arr[-1]` = count).
    .{ .name = "__min", .params = &.{"unknown"}, .ret = "float" },
    .{ .name = "__max", .params = &.{"unknown"}, .ret = "float" },
    .{ .name = "__sign", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__random", .params = &.{}, .ret = "float" },
    .{ .name = "__ilogb", .params = &.{"float"}, .ret = "int" },
    // Float-returning.
    .{ .name = "__sin", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__cos", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__tan", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__asin", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__acos", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__atan", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__atan2", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__log", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__log10", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__log2", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__exp", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__cbrt", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__trunc", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__acosh", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__asinh", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__atanh", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__copysign", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__cosh", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__erf", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__erfc", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__exp2", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__expm1", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__fabs", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__fdim", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__fma", .params = &.{ "float", "float", "float" }, .ret = "float" },
    .{ .name = "__fmax", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__fmin", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__fmod", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__frexp", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__hypot", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__ldexp", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__lgamma", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__log1p", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__logb", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__modf", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__nan", .params = &.{"string"}, .ret = "float" },
    .{ .name = "__nearbyint", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__nextafter", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__nexttoward", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__remainder", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__remquo", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__rint", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__scalbln", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__scalbn", .params = &.{ "float", "float" }, .ret = "float" },
    .{ .name = "__sinh", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__tanh", .params = &.{"float"}, .ret = "float" },
    .{ .name = "__tgamma", .params = &.{"float"}, .ret = "float" },
    // Integer-returning libm.
    .{ .name = "__llrint", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__llround", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__lrint", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__lround", .params = &.{"float"}, .ret = "int" },
    .{ .name = "__fpclassify", .params = &.{"float"}, .ret = "int" },
    // Value-returning constants.
    .{ .name = "__hugeVal", .params = &.{}, .ret = "float" },
    .{ .name = "__infinity", .params = &.{}, .ret = "float" },
    .{ .name = "__nanValue", .params = &.{}, .ret = "float" },
    // Predicates (bool).
    .{ .name = "__isfinite", .params = &.{"float"}, .ret = "bool" },
    .{ .name = "__isnan", .params = &.{"float"}, .ret = "bool" },
    .{ .name = "__isinf", .params = &.{"float"}, .ret = "bool" },
    .{ .name = "__isgreater", .params = &.{ "float", "float" }, .ret = "bool" },
    .{ .name = "__isgreaterequal", .params = &.{ "float", "float" }, .ret = "bool" },
    .{ .name = "__isless", .params = &.{ "float", "float" }, .ret = "bool" },
    .{ .name = "__islessequal", .params = &.{ "float", "float" }, .ret = "bool" },
    .{ .name = "__islessgreater", .params = &.{ "float", "float" }, .ret = "bool" },
    .{ .name = "__isnormal", .params = &.{"float"}, .ret = "bool" },
    .{ .name = "__isunordered", .params = &.{ "float", "float" }, .ret = "bool" },
    .{ .name = "__signbit", .params = &.{"float"}, .ret = "bool" },

    // ── fs module (std/fs.lls + std/io.lls; mirrors src/vm/builtins/io.zig) ──
    // i64-returning natives return 0 on success and minInt on error; the
    // pointer-returning ones return null on error. The full error-code/payload
    // ABI flows through the pure-LLS wrapper path in std/fs.lls (mapIo).
    .{ .name = "__readFile", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__readLine", .params = &.{"int"}, .ret = "string" },
    .{ .name = "__writeFile", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__appendFile", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__deleteFile", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__exists", .params = &.{"string"}, .ret = "bool" },
    .{ .name = "__mkdir", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__mkdirAll", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__readDir", .params = &.{"string"}, .ret = "[]string" },
    .{ .name = "__stat", .params = &.{"string"}, .ret = "[]float" },
    .{ .name = "__rename", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__copyFile", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__symlink", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__readlink", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__realpath", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__chmod", .params = &.{ "string", "int" }, .ret = "int" },

    // ── runtime support ──
    // `len` of an open slice / native array (`arr[-1]` holds the count).
    .{ .name = "__arrayLen", .params = &.{"unknown"}, .ret = "int" },

    // ── error ABI (see src/runtime/builtins/util.zig) ──
    // `error(name, payload)` literals, `@isError`, `.code` / `.payload`.
    .{ .name = "__err_new", .params = &.{ "string", "unknown" }, .ret = "int" },
    .{ .name = "__err_is", .params = &.{"unknown"}, .ret = "bool" },
    .{ .name = "__err_code", .params = &.{"unknown"}, .ret = "string" },
    .{ .name = "__err_payload", .params = &.{"unknown"}, .ret = "string" },

    // ── syscall module (std/syscall.lls; mirrors src/vm/builtins/syscall.zig) ──
    // Errors are negated error pointers (or error-region pointers for the
    // string-returning natives); `__syscall` returns the raw kernel rc.
    .{ .name = "__syscall", .params = &.{ "int", "unknown" }, .ret = "int" },
    .{ .name = "__sys_nr", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__sys_isError", .params = &.{"int"}, .ret = "bool" },
    .{ .name = "__sys_errno", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__sys_errName", .params = &.{"int"}, .ret = "string" },
    .{ .name = "__sys_read", .params = &.{ "int", "unknown" }, .ret = "int" },
    .{ .name = "__sys_write", .params = &.{ "int", "unknown" }, .ret = "int" },
    .{ .name = "__sys_writeAll", .params = &.{ "int", "unknown" }, .ret = "int" },
    .{ .name = "__sys_open", .params = &.{ "string", "int", "int" }, .ret = "int", .variadic = true },
    .{ .name = "__sys_close", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__sys_lseek", .params = &.{ "int", "int", "int" }, .ret = "int" },
    .{ .name = "__sys_fsync", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__sys_pipe", .params = &.{}, .ret = "[]int" },
    .{ .name = "__sys_dup", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__sys_dup2", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__sys_getpid", .params = &.{}, .ret = "int" },
    .{ .name = "__sys_getppid", .params = &.{}, .ret = "int" },
    .{ .name = "__sys_getuid", .params = &.{}, .ret = "int" },
    .{ .name = "__sys_geteuid", .params = &.{}, .ret = "int" },
    .{ .name = "__sys_getgid", .params = &.{}, .ret = "int" },
    .{ .name = "__sys_getegid", .params = &.{}, .ret = "int" },
    .{ .name = "__sys_kill", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__sys_chdir", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__sys_getcwd", .params = &.{}, .ret = "string" },
    .{ .name = "__sys_unlink", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__sys_rename", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__sys_mkdir", .params = &.{ "string", "int" }, .ret = "int", .variadic = true },
    .{ .name = "__sys_rmdir", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__sys_access", .params = &.{ "string", "int" }, .ret = "int", .variadic = true },
    .{ .name = "__sys_chmod", .params = &.{ "string", "int" }, .ret = "int" },
    .{ .name = "__sys_symlink", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__sys_readlink", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__sys_ftruncate", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__sys_umask", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__sys_nanosleep", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__sys_fcntl", .params = &.{ "int", "int", "int" }, .ret = "int", .variadic = true },

    // ── buffer module (std/buffer.lls; mirrors src/vm/builtins/buffer.zig) ──
    .{ .name = "__bufferAlloc", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__bufferCreate", .params = &.{}, .ret = "int" },
    .{ .name = "__bufferFromString", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__bufferWriteString", .params = &.{ "int", "int", "string" }, .ret = "int" },
    .{ .name = "__bufferAppendString", .params = &.{ "int", "string" }, .ret = "int" },
    .{ .name = "__bufferReadString", .params = &.{ "int", "int", "int" }, .ret = "string" },
    .{ .name = "__bufferLen", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__bufferGet", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__bufferSet", .params = &.{ "int", "int", "int" }, .ret = "int" },
    .{ .name = "__bufferPush", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__bufferCopy", .params = &.{ "int", "int", "int", "int", "int" }, .ret = "int" },
    .{ .name = "__bufferFill", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__bufferFillRange", .params = &.{ "int", "int", "int", "int" }, .ret = "int" },
    .{ .name = "__bufferResize", .params = &.{ "int", "int" }, .ret = "int" },

    // ── os module (std/os.lls; mirrors src/vm/builtins/os.zig) ──
    .{ .name = "__exec", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__getEnv", .params = &.{"string"}, .ret = "string" },
    .{ .name = "__setEnv", .params = &.{ "string", "string" }, .ret = "int" },
    .{ .name = "__exit", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__cwd", .params = &.{}, .ret = "string" },
    .{ .name = "__chdir", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__pid", .params = &.{}, .ret = "int" },
    .{ .name = "__args", .params = &.{}, .ret = "[]string" },
    .{ .name = "__platform", .params = &.{}, .ret = "string" },

    // ── time module (std/time.lls; mirrors src/vm/builtins/time.zig) ──
    .{ .name = "__now", .params = &.{}, .ret = "int" },
    .{ .name = "__sleep", .params = &.{"int"}, .ret = "int" },

    // ── list module (std/list.lls; mirrors src/vm/builtins/list.zig) ──
    .{ .name = "__listCreate", .params = &.{}, .ret = "int" },
    .{ .name = "__listPush", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__listPop", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__listGet", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__listSet", .params = &.{ "int", "int", "int" }, .ret = "int" },
    .{ .name = "__listLen", .params = &.{"int"}, .ret = "int" },

    // ── map module (std/map.lls; mirrors src/vm/builtins/map.zig) ──
    .{ .name = "__mapCreate", .params = &.{}, .ret = "int" },
    .{ .name = "__mapSet", .params = &.{ "int", "int", "int" }, .ret = "int" },
    .{ .name = "__mapGet", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__mapHas", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__mapDelete", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__mapSize", .params = &.{"int"}, .ret = "int" },

    // ── json module (std/json.lls; mirrors src/vm/builtins/json_builtin.zig) ──
    .{ .name = "__jsonParse", .params = &.{"string"}, .ret = "int" },
    .{ .name = "__jsonStringify", .params = &.{"unknown"}, .ret = "string" },
    .{ .name = "__jsonGet", .params = &.{ "int", "string" }, .ret = "int" },
    .{ .name = "__jsonIndex", .params = &.{ "int", "int" }, .ret = "int" },
    .{ .name = "__jsonLen", .params = &.{"int"}, .ret = "int" },
    .{ .name = "__jsonToString", .params = &.{"int"}, .ret = "string" },

    // ── http module (std/http.lls; mirrors src/vm/builtins/http.zig) ──
    .{ .name = "__fetch", .params = &.{ "string", "string", "unknown" }, .ret = "int" },

    // ── debug module (std/debug.lls; mirrors src/vm/builtins/log.zig + print_ln.zig) ──
    .{ .name = "__hostLog", .params = &.{ "string", "unknown" }, .ret = "int" },
    .{ .name = "__printLn", .params = &.{ "unknown", "unknown", "unknown", "unknown", "unknown" }, .ret = "int" },

} ++ zeroArgInts("__SYS_", &.{
    "read",         "write",       "open",         "openat",     "close",
    "lseek",        "mmap",        "mprotect",     "munmap",     "brk",
    "ioctl",        "access",      "pipe",         "dup",        "dup2",
    "nanosleep",    "getpid",      "socket",       "connect",    "accept",
    "bind",         "listen",      "clone",        "fork",       "execve",
    "exit",         "wait4",       "kill",         "fcntl",      "fsync",
    "ftruncate",    "getcwd",      "chdir",        "rename",     "mkdir",
    "rmdir",        "unlink",      "symlink",      "readlink",   "chmod",
    "umask",        "getuid",      "getgid",       "geteuid",    "getegid",
    "getppid",      "clock_gettime",
}) ++ zeroArgInts("__O_", &.{ "RDONLY", "WRONLY", "RDWR", "CREAT", "EXCL", "TRUNC", "APPEND", "NONBLOCK", "DIRECTORY", "CLOEXEC" }) ++ zeroArgInts("__SEEK_", &.{ "SET", "CUR", "END" }) ++ zeroArgInts("__", &.{
    "STDIN_FILENO", "STDOUT_FILENO", "STDERR_FILENO",
    "F_OK",         "R_OK",          "W_OK",           "X_OK",
    "AT_FDCWD",     "S_IRWXU",       "S_IRUSR",        "S_IWUSR",
    "S_IXUSR",      "S_IRWXG",       "S_IRGRP",        "S_IWGRP",
    "S_IXGRP",      "S_IRWXO",       "S_IROTH",        "S_IWOTH",
    "S_IXOTH",      "SIGTERM",       "SIGKILL",        "SIGINT",
    "SIGHUP",       "SIGUSR1",       "SIGUSR2",        "F_GETFD",
    "F_SETFD",      "F_GETFL",       "F_SETFL",        "FD_CLOEXEC",
});

/// Generate 0-arg `int`-returning native entries (`__SYS_read`, `__O_CREAT`, …)
/// for the syscall constants referenced as primaries by `std/syscall.lls`.
fn zeroArgInts(comptime prefix: []const u8, comptime names: []const []const u8) [names.len]NativeSig {
    var out: [names.len]NativeSig = undefined;
    for (names, 0..) |n, i| out[i] = .{ .name = prefix ++ n, .params = &.{}, .ret = "int" };
    return out;
}

pub fn lookup(name: []const u8) ?*const NativeSig {
    for (&signatures) |*sig| {
        if (std.mem.eql(u8, sig.name, name)) return sig;
    }
    return null;
}

/// True when `name` is a `__`-prefixed native with a known signature that the
/// backend should declare with a real ABI (as opposed to a variadic stub).
pub fn isKnownNative(name: []const u8) bool {
    return lookup(name) != null;
}
