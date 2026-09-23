//! End-to-end tests for the LSP server (`zig-out/bin/llts-lsp`).
//!
//! Each test spawns the installed server binary and speaks real framed
//! JSON-RPC over stdio, asserting on wire behavior: initialization,
//! diagnostics publishing, hover, definition, sync, and protocol
//! robustness. The test step depends on the install step, so the binary
//! is freshly built before the tests run (same pattern as integration.zig).

const std = @import("std");
const posix = std.posix;

const SERVER_PATH = "zig-out/bin/llts-lsp";

/// How long to wait for the server to produce a message before failing.
const reply_timeout_ns: i128 = 10 * std.time.ns_per_s;

const URI = "file:///llts-e2e-doc.lls";

const valid_source = "@func extra() {}\n";
const invalid_source = "@func main() {\n    print(\"hello\")\n}\n";
const struct_source =
    \\@struct Point {
    \\    x: int;
    \\    y: int;
    \\}
    \\
    \\$p = Point { x: 10, y: 20 };
    \\
    \\$y = p.x;
    \\
    \\pub @func main() {
    \\    p.x = 42;
    \\}
    \\
;

/// A live LSP server session over stdio. All per-message allocations go
/// into one arena that is freed on deinit.
const Session = struct {
    child: std.process.Child,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    arena_state: std.heap.ArenaAllocator,
    /// Temporary read deadline override (ns), consumed by the next recv.
    saved_deadline: ?i128 = null,

    fn init(allocator: std.mem.Allocator) !Session {
        var child = std.process.Child.init(&.{SERVER_PATH}, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit; // crash traces show up in test output
        try child.spawn();
        return .{
            .child = child,
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *Session) void {
        _ = self.child.kill() catch return;
        self.arena_state.deinit();
    }

    fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try posix.write(fd, bytes[written..]);
            if (n == 0) return error.BrokenPipe;
            written += n;
        }
    }

    /// Read exactly buf.len bytes, polling with a deadline so a wedged
    /// server fails the test instead of hanging it.
    fn readExpiring(self: *Session, buf: []u8) !void {
        const timeout = self.saved_deadline orelse reply_timeout_ns;
        const deadline = std.time.nanoTimestamp() + timeout;
        var off: usize = 0;
        while (off < buf.len) {
            const remaining = deadline - std.time.nanoTimestamp();
            if (remaining <= 0) return error.Timeout;
            var fds = [_]posix.pollfd{.{ .fd = self.stdout_fd, .events = posix.POLL.IN, .revents = 0 }};
            const timeout_ms: i32 = @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms), std.math.maxInt(i32)));
            const ready = try posix.poll(&fds, timeout_ms);
            if (ready == 0) return error.Timeout;
            const n = try posix.read(self.stdout_fd, buf[off..]);
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }

    fn send(self: *Session, body: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try writeAll(self.stdin_fd, header);
        try writeAll(self.stdin_fd, body);
    }

    /// Read one framed message and parse it as JSON.
    fn recvFramed(self: *Session) !std.json.Value {
        const arena = self.arena_state.allocator();
        var header_buf: [512]u8 = undefined;
        var hlen: usize = 0;
        while (std.mem.indexOf(u8, header_buf[0..hlen], "\r\n\r\n") == null) {
            if (hlen == header_buf.len) return error.HeaderTooLong;
            try self.readExpiring(header_buf[hlen .. hlen + 1]);
            hlen += 1;
        }
        const header_end = std.mem.indexOf(u8, header_buf[0..hlen], "\r\n\r\n").? + 4;

        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, header_buf[0..header_end], "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " \t"), 10);
            }
        }
        if (content_length == 0 or content_length > 4 * 1024 * 1024) return error.BadContentLength;

        const body = try arena.alloc(u8, content_length);
        try self.readExpiring(body);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    }

    fn request(self: *Session, id: i64, method: []const u8, params: []const u8) !std.json.Value {
        const arena = self.arena_state.allocator();
        const body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
        try self.send(body);
        return self.recvFramed();
    }

    fn notify(self: *Session, method: []const u8, params: []const u8) !void {
        const arena = self.arena_state.allocator();
        const body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params });
        try self.send(body);
    }

    /// Receive messages until the response with `id` arrives.
    /// Notifications are skipped (but consumed).
    fn waitForResponse(self: *Session, id: i64) !std.json.Value {
        while (true) {
            const v = try self.recvFramed();
            if (v != .object) continue;
            const got_id = v.object.get("id") orelse continue; // notification
            if (got_id != .integer) continue;
            if (got_id.integer == id) return v;
        }
    }

    /// Receive messages until a publishDiagnostics notification arrives.
    fn waitForDiagnostics(self: *Session) !std.json.Value {
        return self.waitForDiagnosticsDeadline(reply_timeout_ns);
    }

    /// Same, but with a custom deadline (in ns) — lets tests assert that
    /// nothing arrives within a short window.
    fn waitForDiagnosticsDeadline(self: *Session, deadline_ns: i128) !std.json.Value {
        self.saved_deadline = deadline_ns;
        errdefer self.saved_deadline = null;
        while (true) {
            const v = try self.recvFramed();
            if (v != .object) continue;
            const method = v.object.get("method") orelse continue;
            if (method != .string) continue;
            if (std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) return v;
        }
    }

    fn getDiagnostics(v: std.json.Value) !std.json.Value {
        if (v != .object) return error.Unexpected;
        const params = v.object.get("params") orelse return error.Unexpected;
        if (params != .object) return error.Unexpected;
        return params.object.get("diagnostics") orelse error.Unexpected;
    }
};

/// initialize + initialized + didOpen, then drain the first diagnostics.
fn startSession(allocator: std.mem.Allocator, source: []const u8) !Session {
    var session = try Session.init(allocator);
    errdefer session.deinit();

    _ = try session.request(1, "initialize", "{\"capabilities\":{}}");
    try session.notify("initialized", "{}");
    const open_params = try std.fmt.allocPrint(
        session.arena_state.allocator(),
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"llts\",\"version\":1,\"text\":{f}}}}}",
        .{ URI, std.json.fmt(source, .{}) },
    );
    try session.notify("textDocument/didOpen", open_params);
    _ = try session.waitForDiagnostics();
    return session;
}

test "initialize reports capabilities" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator);
    defer session.deinit();

    const resp = try session.request(1, "initialize", "{\"capabilities\":{}}");
    try std.testing.expect(resp == .object);
    const result = resp.object.get("result") orelse return error.MissingResult;
    const caps = result.object.get("capabilities") orelse return error.MissingCapabilities;
    try std.testing.expectEqual(true, caps.object.get("hoverProvider").?.bool);
    try std.testing.expectEqual(true, caps.object.get("definitionProvider").?.bool);
    try std.testing.expectEqual(@as(i64, 1), caps.object.get("textDocumentSync").?.integer);
}

test "didOpen publishes parse diagnostics" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, invalid_source);
    defer session.deinit();

    // Reopen a second doc with the broken source so we can observe it.
    const params = try std.fmt.allocPrint(
        session.arena_state.allocator(),
        "{{\"textDocument\":{{\"uri\":\"file:///llts-e2e-broken.lls\",\"languageId\":\"llts\",\"version\":1,\"text\":{f}}}}}",
        .{std.json.fmt(invalid_source, .{})},
    );
    try session.notify("textDocument/didOpen", params);
    const diag = try session.waitForDiagnostics();
    const diags = try Session.getDiagnostics(diag);
    try std.testing.expectEqual(@as(usize, 1), diags.array.items.len);
    const first = diags.array.items[0];
    try std.testing.expect(first.object.get("message").?.string.len > 0);
    try std.testing.expectEqual(@as(i64, 1), first.object.get("severity").?.integer);
    try std.testing.expectEqual(@as(i64, 2), first.object.get("range").?.object.get("start").?.object.get("line").?.integer);
}

test "didOpen of valid source publishes empty diagnostics" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    const params = try std.fmt.allocPrint(
        session.arena_state.allocator(),
        "{{\"textDocument\":{{\"uri\":\"file:///llts-e2e-clean.lls\",\"languageId\":\"llts\",\"version\":1,\"text\":{f}}}}}",
        .{std.json.fmt(valid_source, .{})},
    );
    try session.notify("textDocument/didOpen", params);
    const diag = try session.waitForDiagnostics();
    const diags = try Session.getDiagnostics(diag);
    try std.testing.expectEqual(@as(usize, 0), diags.array.items.len);
}

test "hover shows function signature" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    const resp = try session.request(2, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":0,"character":7}}
    );
    const result = resp.object.get("result") orelse return error.MissingResult;
    const value = result.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "@func extra") != null);
}

test "hover on member access shows field type" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, struct_source);
    defer session.deinit();

    // `x` in `$y = p.x;` (line 7, char 7, 0-based)
    const resp = try session.request(2, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":7,"character":7}}
    );
    const result = resp.object.get("result") orelse return error.MissingResult;
    const value = result.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "unknown") == null);
}

test "hover on assignment target member shows field type" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, struct_source);
    defer session.deinit();

    // `x` in `p.x = 42;` (line 10, char 6, 0-based): assignment LHS recording
    const resp = try session.request(2, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":10,"character":6}}
    );
    const result = resp.object.get("result") orelse return error.MissingResult;
    const value = result.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "unknown") == null);
}

test "definition returns declaration location" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    const resp = try session.request(3, "textDocument/definition",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":0,"character":7}}
    );
    const result = resp.object.get("result") orelse return error.MissingResult;
    try std.testing.expectEqualStrings(URI, result.object.get("uri").?.string);
    const start = result.object.get("range").?.object.get("start").?;
    try std.testing.expectEqual(@as(i64, 0), start.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 6), start.object.get("character").?.integer);
}

test "didChange applies all contentChanges" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    // Two full-document changes: the first is broken, the second valid.
    // If the server applied only contentChanges[0], we would see an error.
    try session.notify("textDocument/didChange",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls","version":2},"contentChanges":[{"text":"@func oops( {\n"},{"text":"@func fixed() {\n  print(1);\n}\n"}]}
    );
    const diag = try session.waitForDiagnostics();
    const diags = try Session.getDiagnostics(diag);
    try std.testing.expectEqual(@as(usize, 0), diags.array.items.len);
}

test "didChange reanalysis updates hover" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    try session.notify("textDocument/didChange",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls","version":2},"contentChanges":[{"text":"@func renamed() {}\n"}]}
    );
    _ = try session.waitForDiagnostics();

    const resp = try session.request(4, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":0,"character":7}}
    );
    const result = resp.object.get("result") orelse return error.MissingResult;
    const value = result.object.get("contents").?.object.get("value").?.string;
    try std.testing.expect(std.mem.indexOf(u8, value, "renamed") != null);
}

test "didClose clears diagnostics" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator);
    defer session.deinit();

    _ = try session.request(1, "initialize", "{\"capabilities\":{}}");
    try session.notify("initialized", "{}");
    const open_params = try std.fmt.allocPrint(
        session.arena_state.allocator(),
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"llts\",\"version\":1,\"text\":{f}}}}}",
        .{ URI, std.json.fmt(invalid_source, .{}) },
    );
    try session.notify("textDocument/didOpen", open_params);

    const before = try session.waitForDiagnostics();
    const diags_before = try Session.getDiagnostics(before);
    try std.testing.expect(diags_before.array.items.len > 0);

    try session.notify("textDocument/didClose", "{\"textDocument\":{\"uri\":\"file:///llts-e2e-doc.lls\"}}");
    const after = try session.waitForDiagnostics();
    const diags_after = try Session.getDiagnostics(after);
    try std.testing.expectEqual(@as(usize, 0), diags_after.array.items.len);

    // Server must stay alive after closing: a follow-up request is answered.
    const resp = try session.request(2, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":0,"character":0}}
    );
    try std.testing.expect(resp == .object);
    try std.testing.expect(resp.object.get("result") != null);
}

test "unknown request returns MethodNotFound" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    const resp = try session.request(5, "textDocument/noSuchFeature", "{}");
    const err = resp.object.get("error") orelse return error.MissingError;
    try std.testing.expectEqual(@as(i64, -32601), err.object.get("code").?.integer);
}

test "unknown notifications are ignored" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    try session.notify("$foo/bar", "{}");
    // If the server had crashed on the unknown notification, this request
    // would time out.
    const resp = try session.request(6, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":0,"character":0}}
    );
    try std.testing.expect(resp == .object);
    try std.testing.expect(resp.object.get("result") != null);
}

test "$/cancelRequest is a no-op" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    try session.notify("$/cancelRequest", "{\"id\":999}");
    const resp = try session.request(7, "textDocument/hover",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls"},"position":{"line":0,"character":0}}
    );
    try std.testing.expect(resp == .object);
    try std.testing.expect(resp.object.get("result") != null);
}

test "type errors surface as diagnostics with token ranges" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator);
    defer session.deinit();

    _ = try session.request(1, "initialize", "{\"capabilities\":{}}");
    try session.notify("initialized", "{}");
    const type_error_source =
        \\@func take(x: i32) {}
        \\@func main() {
        \\    take("str");
        \\}
    ;
    const params = try std.fmt.allocPrint(
        session.arena_state.allocator(),
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"llts\",\"version\":1,\"text\":{f}}}}}",
        .{ URI, std.json.fmt(type_error_source, .{}) },
    );
    try session.notify("textDocument/didOpen", params);

    const diag = try session.waitForDiagnostics();
    const diags = try Session.getDiagnostics(diag);
    try std.testing.expectEqual(@as(usize, 1), diags.array.items.len);
    const first = diags.array.items[0];

    // The compiler's message, not just a parse error.
    const msg = first.object.get("message").?.string;
    try std.testing.expect(std.mem.indexOf(u8, msg, "not assignable") != null);

    // 1-based compiler loc (3:10) converted to 0-based LSP (2:9).
    const range = first.object.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 2), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 9), range.get("start").?.object.get("character").?.integer);
    // The range covers the whole `"str"` token (5 chars), not one char.
    const end_char = range.get("end").?.object.get("character").?.integer;
    try std.testing.expectEqual(@as(i64, 14), end_char);
}

test "didChange diagnostics are debounced" {
    const allocator = std.testing.allocator;
    var session = try startSession(allocator, valid_source);
    defer session.deinit();

    // A broken edit should NOT publish synchronously anymore.
    try session.notify("textDocument/didChange",
        \\{"textDocument":{"uri":"file:///llts-e2e-doc.lls","version":2},"contentChanges":[{"text":"@func broken( {\n"}]}
    );
    try std.testing.expectError(
        error.Timeout,
        session.waitForDiagnosticsDeadline(30),
    );

    // But it must arrive once the debounce window elapses.
    const diag = try session.waitForDiagnostics();
    const diags = try Session.getDiagnostics(diag);
    try std.testing.expect(diags.array.items.len > 0);
}

 test "shutdown responds then exit terminates cleanly" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator);
    defer session.deinit();

    _ = try session.request(1, "initialize", "{\"capabilities\":{}}");
    const resp = try session.request(2, "shutdown", "{}");
    try std.testing.expect(resp == .object);
    try std.testing.expect(resp.object.get("result") != null);

    try session.notify("exit", "{}");
    const term = try session.child.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}
