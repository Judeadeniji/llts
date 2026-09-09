const std = @import("std");

pub fn readByte(fd: std.posix.fd_t) !u8 {
    var buf: [1]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n == 0) return error.UnexpectedEndOfStream;
    return buf[0];
}

pub fn readLine(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const b = try readByte(fd);
        if (b == '\n') {
            var res = buf[0..len];
            if (res.len > 0 and res[res.len - 1] == '\r') {
                res.len -= 1;
            }
            return res;
        }
        buf[len] = b;
        len += 1;
    }
    return error.BufferTooSmall;
}

pub fn readAll(fd: std.posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        total += n;
    }
}

pub fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.write(fd, buf[total..]);
        total += n;
    }
}

pub fn sendResponse(allocator: std.mem.Allocator, stdout: std.posix.fd_t, id: std.json.Value, result: anytype) !void {
    var string_buf = std.ArrayList(u8).empty;
    defer string_buf.deinit(allocator);

    try std.fmt.format(string_buf.writer(allocator), "{f}", .{std.json.fmt(.{
        .jsonrpc = "2.0",
        .id = id,
        .result = result,
    }, .{})});

    var header_buf = std.ArrayList(u8).empty;
    defer header_buf.deinit(allocator);
    try std.fmt.format(header_buf.writer(allocator), "Content-Length: {d}\r\n\r\n", .{string_buf.items.len});

    try writeAll(stdout, header_buf.items);
    try writeAll(stdout, string_buf.items);
}
