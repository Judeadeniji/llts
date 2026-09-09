const std = @import("std");
const llts = @import("llts");
const state = @import("state.zig");
const transport = @import("transport.zig");

pub fn handleMessage(server: *state.ServerState, stdout: std.posix.fd_t, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, server.allocator, body, .{}) catch return;
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
                try transport.sendResponse(server.allocator, stdout, id.?, .{
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
                try transport.sendResponse(server.allocator, stdout, id.?, null);
            }
        } else if (std.mem.eql(u8, method_str, "exit")) {
            std.posix.exit(0);
        } else if (std.mem.eql(u8, method_str, "textDocument/didOpen")) {
            try handleDidOpen(server, params);
        } else if (std.mem.eql(u8, method_str, "textDocument/didChange")) {
            try handleDidChange(server, params);
        } else if (std.mem.eql(u8, method_str, "textDocument/didClose")) {
            try handleDidClose(server, params);
        } else if (std.mem.eql(u8, method_str, "textDocument/hover")) {
            try handleHover(server, stdout, id, params);
        } else if (std.mem.eql(u8, method_str, "textDocument/definition")) {
            try handleDefinition(server, stdout, id, params);
        }
    }
}

fn handleDidOpen(server: *state.ServerState, params: ?std.json.Value) !void {
    if (params != null and params.? == .object) {
        const textDoc = params.?.object.get("textDocument");
        if (textDoc != null and textDoc.? == .object) {
            const uri = textDoc.?.object.get("uri");
            const text = textDoc.?.object.get("text");
            if (uri != null and uri.? == .string and text != null and text.? == .string) {
                try server.updateDocument(uri.?.string, text.?.string);
            }
        }
    }
}

fn handleDidChange(server: *state.ServerState, params: ?std.json.Value) !void {
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
                        try server.updateDocument(uri.?.string, text.?.string);
                    }
                }
            }
        }
    }
}

fn handleDidClose(server: *state.ServerState, params: ?std.json.Value) !void {
    if (params != null and params.? == .object) {
        const textDoc = params.?.object.get("textDocument");
        if (textDoc != null and textDoc.? == .object) {
            const uri = textDoc.?.object.get("uri");
            if (uri != null and uri.? == .string) {
                server.removeDocument(uri.?.string);
            }
        }
    }
}

fn handleHover(server: *state.ServerState, stdout: std.posix.fd_t, id: ?std.json.Value, params: ?std.json.Value) !void {
    if (id == null or params == null or params.? != .object) return;

    var hover_value: []const u8 = "No basic type info found.";
    
    const textDoc = params.?.object.get("textDocument");
    const pos = params.?.object.get("position");
    
    if (textDoc != null and textDoc.? == .object and pos != null and pos.? == .object) {
        const uri = textDoc.?.object.get("uri");
        const line_val = pos.?.object.get("line");
        const char_val = pos.?.object.get("character");
        
        if (uri != null and uri.? == .string and line_val != null and char_val != null) {
            const target_line = @as(u32, @intCast(line_val.?.integer)) + 1;
            const target_col = @as(u32, @intCast(char_val.?.integer)) + 1;
            
            if (server.getDocument(uri.?.string)) |source| {
                if (llts.scanner.scan(server.allocator, source, uri.?.string)) |scan_result| {
                    var result = scan_result;
                    defer llts.scanner.deinitScanResult(&result);
                    
                    for (result.tokens.items) |t| {
                        if (t.line == target_line) {
                            const end_col = t.column + @as(u32, @intCast(t.value.len));
                            if (target_col >= t.column and target_col <= end_col) {
                                var type_str: []const u8 = "unknown";
                                var prefix: []const u8 = "";
                                
                                switch (t.type) {
                                    .number, .hex, .octal, .binary => {
                                        type_str = "int";
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
                                        type_str = "?";
                                    },
                                    else => {},
                                }
                                
                                if (t.type == .delimiter or t.type == .bin_op or t.type == .unary_op or t.type == .assign_op or t.type == .keyword or t.type == .eof) {
                                    break;
                                }

                                const formatted = std.fmt.allocPrint(server.allocator, 
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

    try transport.sendResponse(server.allocator, stdout, id.?, .{
        .contents = .{
            .kind = "markdown",
            .value = hover_value,
        },
    });
}

fn handleDefinition(server: *state.ServerState, stdout: std.posix.fd_t, id: ?std.json.Value, params: ?std.json.Value) !void {
    if (id == null or params == null or params.? != .object) return;

    
    const textDoc = params.?.object.get("textDocument");
    const pos = params.?.object.get("position");
    
    if (textDoc != null and textDoc.? == .object and pos != null and pos.? == .object) {
        const uri = textDoc.?.object.get("uri");
        const line_val = pos.?.object.get("line");
        const char_val = pos.?.object.get("character");
        
        if (uri != null and uri.? == .string and line_val != null and char_val != null) {
            const target_line = @as(u32, @intCast(line_val.?.integer)) + 1;
            const target_col = @as(u32, @intCast(char_val.?.integer)) + 1;
            
            if (server.getDocument(uri.?.string)) |source| {
                if (llts.scanner.scan(server.allocator, source, uri.?.string)) |scan_result| {
                    var result = scan_result;
                    defer llts.scanner.deinitScanResult(&result);
                    
                    var target_name: ?[]const u8 = null;
                    var is_register = false;
                    
                    // 1. Find the name we are hovering on
                    for (result.tokens.items) |t| {
                        if (t.line == target_line) {
                            const end_col = t.column + @as(u32, @intCast(t.value.len));
                            if (target_col >= t.column and target_col <= end_col) {
                                if (t.type == .identifier or t.type == .v_register) {
                                    target_name = t.value;
                                    is_register = (t.type == .v_register);
                                }
                                break;
                            }
                        }
                    }

                    // 2. Scan from the top to find the first declaration
                    if (target_name) |name| {
                        var decl_token: ?llts.scanner.Token = null;
                        
                        for (result.tokens.items, 0..) |t, i| {
                            if (is_register) {
                                // For registers, the first time we see it on the LHS of `=` or preceded by `@const` is the decl
                                if (t.type == .v_register and std.mem.eql(u8, t.value, name)) {
                                    const prev = if (i > 0) result.tokens.items[i - 1] else null;
                                    const next = if (i + 1 < result.tokens.items.len) result.tokens.items[i + 1] else null;
                                    
                                    const is_const = prev != null and prev.?.type == .compiler_keyword and std.mem.eql(u8, prev.?.value, "const");
                                    const is_assign = next != null and next.?.type == .assign_op;
                                    
                                    if (is_const or is_assign) {
                                        decl_token = t;
                                        break;
                                    }
                                }
                            } else {
                                // For identifiers, look for `@func foo`, `@struct foo`, `@enum foo`, etc.
                                if (t.type == .identifier and std.mem.eql(u8, t.value, name)) {
                                    const prev = if (i > 0) result.tokens.items[i - 1] else null;
                                    if (prev != null and prev.?.type == .compiler_keyword) {
                                        const kw = prev.?.value;
                                        if (std.mem.eql(u8, kw, "func") or 
                                            std.mem.eql(u8, kw, "struct") or 
                                            std.mem.eql(u8, kw, "enum") or 
                                            std.mem.eql(u8, kw, "type") or 
                                            std.mem.eql(u8, kw, "error")) 
                                        {
                                            decl_token = t;
                                            break;
                                        }
                                    }
                                }
                            }
                        }

                        // 3. Populate result
                        if (decl_token) |tok| {
                            try transport.sendResponse(server.allocator, stdout, id.?, .{
                                .uri = uri.?.string,
                                .range = .{
                                    .start = .{
                                        .line = tok.line - 1,
                                        .character = tok.column - 1,
                                    },
                                    .end = .{
                                        .line = tok.line - 1,
                                        .character = tok.column - 1 + @as(i64, @intCast(tok.value.len)),
                                    },
                                },
                            });
                            return;
                        }
                    }
                } else |_| {}
            }
        }
    }

    try transport.sendResponse(server.allocator, stdout, id.?, null);
}
