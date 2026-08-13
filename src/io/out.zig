const std = @import("std");

/// Write all of `bytes` to stdout via posix (handles short writes / EINTR).
pub fn writeStdout(bytes: []const u8) void {
    writeAll(std.posix.STDOUT_FILENO, bytes);
}

/// Write all of `bytes` to stderr via posix (handles short writes / EINTR).
pub fn writeStderr(bytes: []const u8) void {
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
