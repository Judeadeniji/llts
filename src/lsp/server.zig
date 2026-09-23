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

        // Block until input arrives OR the next debounced diagnostics
        // publish is due. A poll timeout of -1 blocks indefinitely.
        const timeout_ms = server_state.nextDiagnosticsTimeout(std.time.milliTimestamp()) orelse -1;
        var fds = [_]std.posix.pollfd{.{ .fd = stdin, .events = std.posix.POLL.IN, .revents = 0 }};
        // On a poll error fall through to the read path: readLine surfaces
        // the real condition (and blocks/errs harmlessly if nothing arrived).
        const ready = std.posix.poll(&fds, timeout_ms) catch 1;
        if (ready == 0) {
            // Deadline hit: publish diagnostics for edited documents,
            // then go back to waiting.
            handlers.flushDueDiagnostics(&server_state, stdout);
            continue;
        }

        // Read headers
        while (true) {
            const line = transport.readLine(stdin, &header_buf) catch |err| {
                if (err == error.UnexpectedEndOfStream) return;
                return err;
            };

            if (line.len == 0) break;

            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                const rest = std.mem.trim(u8, line["Content-Length:".len..], " \t");
                content_length = try std.fmt.parseInt(usize, rest, 10);
            }
        }

        if (content_length == 0) continue;

        const body = try allocator.alloc(u8, content_length);
        defer allocator.free(body);

        try transport.readAll(stdin, body);

        try handlers.handleMessage(&server_state, stdout, body);

        // Cover the case where the deadline passed while we were busy with
        // the last message (long analysis, burst of buffered edits).
        if (server_state.nextDiagnosticsTimeout(std.time.milliTimestamp()) == 0) {
            handlers.flushDueDiagnostics(&server_state, stdout);
        }
    }
}
