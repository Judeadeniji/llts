const std = @import("std");

/// Write all of `bytes` to stdout via posix (handles short writes / EINTR).
pub fn writeStdout(bytes: []const u8) void {
    writeAll(std.posix.STDOUT_FILENO, bytes);
}

/// When set, stderr output is appended here instead of reaching the terminal.
/// Tests use it to assert on diagnostics without spawning a process.
var stderr_sink: ?struct { list: *std.ArrayList(u8), allocator: std.mem.Allocator } = null;

/// Redirect (or, with `null`, restore) stderr for the current thread. Callers
/// must restore it before the sink goes out of scope, and must pass the same
/// allocator the list was created with.
pub fn captureStderr(sink: ?*std.ArrayList(u8), allocator: std.mem.Allocator) void {
    stderr_sink = if (sink) |list| .{ .list = list, .allocator = allocator } else null;
}

/// Write all of `bytes` to stderr via posix (handles short writes / EINTR).
pub fn writeStderr(bytes: []const u8) void {
    if (stderr_sink) |sink| {
        sink.list.appendSlice(sink.allocator, bytes) catch {};
        return;
    }
    writeAll(std.posix.STDERR_FILENO, bytes);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch {
            return;
        };
        if (n == 0) return;
        remaining = remaining[n..];
    }
}

fn formatToOwned(comptime fmt: []const u8, args: anytype) ?[]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch null;
}

/// Format and write to stderr. Never uses `std.debug.print`.
pub fn printStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |formatted| {
        writeStderr(formatted);
        return;
    } else |_| {
        const owned = formatToOwned(fmt, args) orelse {
            writeStderr("(log format failed)\n");
            return;
        };
        defer std.heap.page_allocator.free(owned);
        writeStderr(owned);
    }
}

pub fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |formatted| {
        writeStdout(formatted);
        return;
    } else |_| {
        const owned = formatToOwned(fmt, args) orelse {
            writeStdout("(print format failed)\n");
            return;
        };
        defer std.heap.page_allocator.free(owned);
        writeStdout(owned);
    }
}
