//! Minimal fd I/O and the LLTS trap path for the native runtime.
//!
//! Uses the libc `write` / `exit` symbols (build wiring links libc wherever the
//! runtime is used) instead of `std.posix` / `std.process`. All user-facing
//! failure output is produced by the runtime — Zig never prints, panics, or
//! reports an LLTS failure on its own.

const std = @import("std");
const trace = @import("trace.zig");

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn exit(code: c_int) noreturn;

pub const STDOUT: c_int = 1;
pub const STDERR: c_int = 2;

/// Test hook: suppress stderr writes so trap-path tests stay quiet.
pub var silence_stderr: bool = false;

/// Test hook: redirect stderr into a buffer instead of the real fd.
pub const Capture = struct {
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),
};
pub var stderr_capture: ?Capture = null;

/// Write all bytes, mirroring `src/io/out.zig`: short writes continue, a
/// non-positive result drops the remainder (same tolerance as the VM's
/// unbuffered stdout/stderr).
pub fn writeAll(fd: c_int, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn writeStdout(bytes: []const u8) void {
    writeAll(STDOUT, bytes);
}

pub fn writeStderr(bytes: []const u8) void {
    if (silence_stderr) return;
    if (stderr_capture) |cap| {
        cap.buf.appendSlice(cap.alloc, bytes) catch {};
        return;
    }
    writeAll(STDERR, bytes);
}

/// Report an LLTS runtime trap: `Error: <msg>`, then the shadow stack trace.
///
/// Returns `error.RuntimeError` purely as the internal unwind signal; the
/// emitter's `main` glue catches it and exits 1. No LLTS cleanup runs on this
/// path (LLTS `defer` is emitted as explicit return-path code, never Zig
/// `defer`), matching the VM's `runtimeFail`.
pub fn fail(comptime fmt: []const u8, args: anytype) error{RuntimeError}!noreturn {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Error: " ++ fmt ++ "\n", args) catch {
        writeStderr("Error: runtime diagnostic too long\n");
        trace.printActive(&writeStderr);
        return error.RuntimeError;
    };
    writeStderr(line);
    trace.printActive(&writeStderr);
    return error.RuntimeError;
}

/// Report a runtime trap with a preformatted message (VM `fail(vm, msg)` parity).
pub fn failMsg(msg: []const u8) error{RuntimeError}!noreturn {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Error: {s}\n", .{msg}) catch {
        writeStderr("Error: runtime diagnostic too long\n");
        trace.printActive(&writeStderr);
        return error.RuntimeError;
    };
    writeStderr(line);
    trace.printActive(&writeStderr);
    return error.RuntimeError;
}

/// Terminate the process with an exit code — for emitted `main` glue.
pub fn exitProcess(code: i32) noreturn {
    exit(@intCast(code));
}
