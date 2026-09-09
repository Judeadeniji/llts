const std = @import("std");
const llts = @import("llts");

fn readByte(fd: std.posix.fd_t) !u8 {
    var buf: [1]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n == 0) return error.UnexpectedEndOfStream;
    return buf[0];
}

fn readLine(fd: std.posix.fd_t, buf: []u8) ![]u8 {
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

fn readAll(fd: std.posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        total += n;
    }
}

fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.write(fd, buf[total..]);
        total += n;
    }
}

var documents: std.StringHashMap([]const u8) = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    documents = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = documents.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        documents.deinit();
    }

    const stdin = std.posix.STDIN_FILENO;
    const stdout = std.posix.STDOUT_FILENO;

    while (true) {
        var content_length: usize = 0;
        var header_buf: [1024]u8 = undefined;

        // Read headers
        while (true) {
            const line = readLine(stdin, &header_buf) catch |err| {
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

        try readAll(stdin, body);

        try handleMessage(allocator, stdout, body);
    }
}

fn handleMessage(allocator: std.mem.Allocator, stdout: std.posix.fd_t, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const method = root.object.get("method");
    const id = root.object.get("id");
    const params = root.object.get("params");

    if (method != null and method.? == .string) {
        const method_str = method.?.string;
        if (std.mem.eql(u8, method_str, "initialize")) {
            if (id != null) {
                try sendResponse(allocator, stdout, id.?, .{
                    .capabilities = .{
                        .textDocumentSync = 1, // Full sync
                        .hoverProvider = true,
                        .definitionProvider = true,
                    },
                    .serverInfo = .{
                        .name = "llts-lsp",
                        .version = "0.0.1",
                    },
                });
            }
        } else if (std.mem.eql(u8, method_str, "shutdown")) {
            if (id != null) {
                try sendResponse(allocator, stdout, id.?, null);
            }
        } else if (std.mem.eql(u8, method_str, "exit")) {
            std.posix.exit(0);
        } else if (std.mem.eql(u8, method_str, "textDocument/didOpen")) {
            if (params != null and params.? == .object) {
                const textDoc = params.?.object.get("textDocument");
                if (textDoc != null and textDoc.? == .object) {
                    const uri = textDoc.?.object.get("uri");
                    const text = textDoc.?.object.get("text");
                    if (uri != null and uri.? == .string and text != null and text.? == .string) {
                        try updateDocument(allocator, uri.?.string, text.?.string);
                    }
                }
            }
        } else if (std.mem.eql(u8, method_str, "textDocument/didChange")) {
            if (params != null and params.? == .object) {
                const textDoc = params.?.object.get("textDocument");
                const contentChanges = params.?.object.get("contentChanges");
                if (textDoc != null and textDoc.? == .object and contentChanges != null and contentChanges.? == .array) {
                    const uri = textDoc.?.object.get("uri");
                    if (uri != null and uri.? == .string and contentChanges.?.array.items.len > 0) {
                        const change = contentChanges.?.array.items[0];
                        if (change == .object) {
                            const text = change.object.get("text");
                            if (text != null and text.? == .string) {
                                try updateDocument(allocator, uri.?.string, text.?.string);
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, method_str, "textDocument/didClose")) {
            if (params != null and params.? == .object) {
                const textDoc = params.?.object.get("textDocument");
                if (textDoc != null and textDoc.? == .object) {
                    const uri = textDoc.?.object.get("uri");
                    if (uri != null and uri.? == .string) {
                        if (documents.fetchRemove(uri.?.string)) |kv| {
                            allocator.free(kv.key);
                            allocator.free(kv.value);
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, method_str, "textDocument/hover")) {
            if (id != null and params != null and params.? == .object) {
                var hover_value: []const u8 = "No basic type info found.";
                
                const textDoc = params.?.object.get("textDocument");
                const pos = params.?.object.get("position");
                if (textDoc != null and textDoc.? == .object and pos != null and pos.? == .object) {
                    const uri = textDoc.?.object.get("uri");
                    const line_val = pos.?.object.get("line");
                    const char_val = pos.?.object.get("character");
                    
                    if (uri != null and uri.? == .string and line_val != null and char_val != null) {
                        const target_line = @as(u32, @intCast(line_val.?.integer)) + 1; // LSP is 0-indexed, scanner is 1-indexed
                        const target_col = @as(u32, @intCast(char_val.?.integer)) + 1;
                        
                        if (documents.get(uri.?.string)) |source| {
                            if (llts.scanner.scan(allocator, source, uri.?.string)) |scan_result| {
                                var result = scan_result; // Make it mutable to pass by ref if needed, but deinit is fine with pointer
                                defer llts.scanner.deinitScanResult(&result);
                                
                                for (result.tokens.items) |t| {
                                    if (t.line == target_line) {
                                        const end_col = t.column + @as(u32, @intCast(t.value.len));
                                        if (target_col >= t.column and target_col <= end_col) {
                                            // Format to look like a real LSP!
                                            var type_str: []const u8 = "unknown";
                                            var prefix: []const u8 = "";
                                            
                                            switch (t.type) {
                                                .number, .hex, .octal, .binary => {
                                                    type_str = "int"; // Assuming basic int for numbers
                                                    prefix = "(literal) ";
                                                },
                                                .boolean => {
                                                    type_str = "bool";
                                                    prefix = "(literal) ";
                                                },
                                                .string => {
                                                    type_str = "[]const u8";
                                                    prefix = "(literal) ";
                                                },
                                                .v_register => {
                                                    type_str = "register";
                                                    prefix = "(virtual) ";
                                                },
                                                .compiler_keyword => {
                                                    type_str = "intrinsic";
                                                    prefix = "(builtin) ";
                                                },
                                                .identifier => {
                                                    type_str = "?"; // Unknown until typechecking
                                                },
                                                else => {},
                                            }
                                            
                                            if (t.type == .delimiter or t.type == .bin_op or t.type == .unary_op or t.type == .assign_op or t.type == .keyword or t.type == .eof) {
                                                break; // Don't show hover for random punctuation
                                            }

                                            // We use std.fmt.allocPrint to format the markdown block
                                            const formatted = std.fmt.allocPrint(allocator, 
                                                "```llts\n{s}{s}: {s}\n```", 
                                                .{ prefix, t.value, type_str }
                                            ) catch "Error formatting hover";
                                            
                                            hover_value = formatted;
                                            break;
                                        }
                                    }
                                }
                            } else |_| {}
                        }
                    }
                }

                try sendResponse(allocator, stdout, id.?, .{
                    .contents = .{
                        .kind = "markdown",
                        .value = hover_value,
                    },
                });
            }
        }
    }
}

fn updateDocument(allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
    const key = try allocator.dupe(u8, uri);
    const val = try allocator.dupe(u8, text);
    
    if (documents.fetchRemove(uri)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    
    try documents.put(key, val);
}

fn sendResponse(allocator: std.mem.Allocator, stdout: std.posix.fd_t, id: std.json.Value, result: anytype) !void {
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
