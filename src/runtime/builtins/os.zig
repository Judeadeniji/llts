//! Process/environment natives backing `std/os.lls` (mirrors
//! `src/vm/builtins/os.zig`). `__exec` runs `sh -c cmd` and returns stdout;
//! string-returning natives return error-region pointers on failure (see
//! `util.zig`); i64-returning ones return negated error pointers.

const std = @import("std");
const util = @import("util.zig");

const cstr = util.cstr;
const dupBytes = util.dupBytes;

extern "c" fn setenv(name: [*:0]const u8, val: [*:0]const u8, overwrite: c_int) c_int;

fn errI(err: anyerror) i64 {
    return util.errNew(dupBytes("ExecError"), @intFromPtr(dupBytes(@errorName(err))));
}

fn errPtr(err: anyerror) [*:0]u8 {
    return @ptrFromInt(util.errNewAddr(dupBytes("ExecError"), @intFromPtr(dupBytes(@errorName(err)))));
}

export fn __exec(cmd: [*:0]const u8) ?[*:0]u8 {
    var child = std.process.Child.init(&.{ "sh", "-c", cstr(cmd) }, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| return errPtr(err);
    const stdout = child.stdout.?.readToEndAlloc(std.heap.page_allocator, 1024 * 1024 * 10) catch |err| {
        _ = child.wait() catch {};
        return errPtr(err);
    };
    defer std.heap.page_allocator.free(stdout);
    _ = child.wait() catch |err| return errPtr(err);
    return dupBytes(stdout);
}

export fn __getEnv(key: [*:0]const u8) ?[*:0]u8 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, cstr(key))) |val| {
        defer std.heap.page_allocator.free(val);
        return dupBytes(val);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return errPtr(err),
    }
}

export fn __setEnv(key: [*:0]const u8, val: [*:0]const u8) i64 {
    if (setenv(key, val, 1) != 0) return errI(error.AccessDenied);
    return 0;
}

export fn __exit(code_in: i64) i64 {
    const code: u8 = @intCast(code_in);
    std.process.exit(code);
}

export fn __cwd() ?[*:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&buf) catch |err| return errPtr(err);
    return dupBytes(cwd);
}

export fn __chdir(dir: [*:0]const u8) i64 {
    std.posix.chdir(cstr(dir)) catch {
        return util.errNew(dupBytes("ChdirError"), @intFromPtr(dupBytes(cstr(dir))));
    };
    return 0;
}

export fn __pid() i64 {
    return @intCast(std.os.linux.getpid());
}

/// `args()` → count-prefixed i64 array of string pointers (`arr[-1]` = count).
extern var __argc_global: c_int;
extern var __argv_global: [*][*:0]const u8;

export fn __args() i64 {
    const alloc = util.strAlloc();
    const argc: usize = @intCast(__argc_global);
    if (argc == 0) return 0;
    // Count-prefixed array: arr[-1] = count, arr[0..count] = strings.
    const slots = alloc.alloc(i64, argc + 1) catch return 0;
    slots[0] = @intCast(argc);
    const argv = __argv_global;
    for (0..argc) |i| {
        slots[i + 1] = @intCast(@intFromPtr(dupBytes(util.cstr(argv[i]))));
    }
    return @intCast(@intFromPtr(slots.ptr + 1));
}

export fn __platform() [*:0]u8 {
    const os_tag = @tagName(@import("builtin").os.tag);
    return dupBytes(os_tag);
}
