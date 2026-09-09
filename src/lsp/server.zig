const std = @import("std");
const state = @import("state.zig");
const transport = @import("transport.zig");
const handlers = @import("handlers.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server_state = state.ServerState.init(allocator);
    defer server_state.deinit();

    const stdin = std.posix.STDIN_FILENO;
    const stdout = std.posix.STDOUT_FILENO;

    while (true) {
        var content_length: usize = 0;
        var header_buf: [1024]u8 = undefined;

        // Read headers
        while (true) {
            const line = transport.readLine(stdin, &header_buf) catch |err| {
                if (err == error.UnexpectedEndOfStream) return;
                return err;
            };

            if (line.len == 0) break;

            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                const len_str = std.mem.trim(u8, line["Content-Length: ".len..], " ");
                content_length = try std.fmt.parseInt(usize, len_str, 10);
            }
        }

        if (content_length == 0) continue;

        const body = try allocator.alloc(u8, content_length);
        defer allocator.free(body);

        try transport.readAll(stdin, body);

        try handlers.handleMessage(&server_state, stdout, body);
    }
}
