const std = @import("std");
const llts = @import("llts");
const state = @import("state.zig");
const transport = @import("transport.zig");
const infer = @import("infer.zig");
const resolve = @import("resolve.zig");

const MethodNotFound: i32 = -32601;
const InternalError: i32 = -32603;

test "wrapCode uses a standard triple-backtick fence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = wrapCode(arena.allocator(), "@enum Color");
    try std.testing.expect(std.mem.startsWith(u8, out, "```llts\n"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\n```"));
    try std.testing.expectEqualStrings("```llts\n@enum Color\n```", out);
}

test "wrapCode widens the fence when content contains backticks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A 1-backtick run can't close a 3-fence (closing needs >= opening
    // length), so the fence stays standard.
    const short = wrapCode(arena.allocator(), "quotes `x` here");
    try std.testing.expectEqualStrings("```llts\nquotes `x` here\n```", short);

    // A run of 4 would close a 3-fence — widen to 5.
    const long = wrapCode(arena.allocator(), "run of ```` four");
    try std.testing.expectEqualStrings("`````llts\nrun of ```` four\n`````", long);
}

/// Diagnostics are capped so a pathological file can't flood the client.
const MAX_DIAGNOSTICS: usize = 100;

/// LSP range for a diagnostic at 1-based `line`/`column`. The end is derived
/// from the token starting at that position when there is one, so squiggles
/// cover the whole name instead of a single character.
fn diagRangeAt(analysis: anytype, line: u32, column: u32) DiagRange {
    const l1 = @max(1, line) - 1;
    const c1 = @max(1, column) - 1;
    var end_char: u32 = c1 + 1;
    for (analysis.scan.tokens.items) |t| {
        if (t.line != line or t.column != column) continue;
        if (t.type == .eof or t.value.len == 0) break; // zero-width: keep 1-char fallback
        // String token values exclude the surrounding quotes — widen to them.
        const quoted: u32 = if (t.type == .string) 2 else 0;
        end_char = t.column - 1 + @as(u32, @intCast(t.value.len)) + quoted;
        break;
    }
    return .{
        .start = .{ .line = l1, .character = c1 },
        .end = .{ .line = l1, .character = end_char },
    };
}

/// Build the diagnostic list for `uri`: parse diagnostics first, then the
/// captured typecheck error (if any, and if it points at this document).
/// Capped at MAX_DIAGNOSTICS with a trailing truncation hint.
fn buildDiagnostics(server: *state.ServerState, ra: std.mem.Allocator, uri: []const u8) []DiagObj {
    var json_diags: std.ArrayList(DiagObj) = .empty;

    if (server.ensureAnalysis(uri)) |analysis| {
        const total = analysis.doc.diagnostics.len +
            (if (analysis.tc_diagnostic != null) @as(usize, 1) else 0);

        for (analysis.doc.diagnostics) |d| {
            if (json_diags.items.len >= MAX_DIAGNOSTICS) break;
            json_diags.append(ra, .{
                .range = diagRangeAt(analysis, d.line, d.column),
                .severity = 1,
                .message = d.message,
            }) catch break;
        }
        if (json_diags.items.len < MAX_DIAGNOSTICS) {
            if (analysis.tc_diagnostic) |tc| {
                json_diags.append(ra, .{
                    .range = diagRangeAt(analysis, tc.line, tc.column),
                    .severity = 1,
                    .message = tc.message,
                }) catch {};
            }
        }

        if (total > MAX_DIAGNOSTICS) {
            const notice = std.fmt.allocPrint(ra, "Further errors truncated ({d} shown).", .{MAX_DIAGNOSTICS}) catch null;
            if (notice) |n| {
                const last = if (json_diags.items.len > 0) json_diags.items[json_diags.items.len - 1].range else DiagRange{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = 0, .character = 1 },
                };
                json_diags.append(ra, .{
                    .range = last,
                    .severity = 4, // hint: not an error itself
                    .message = n,
                }) catch {};
            }
        }
    } else |_| {
        // Analysis failed entirely: publish empty so stale errors clear.
    }

    return json_diags.items;
}

fn publishDiagnostics(server: *state.ServerState, stdout: std.posix.fd_t, ra: std.mem.Allocator, uri: []const u8) !void {
    const diags = buildDiagnostics(server, ra, uri);
    try transport.sendNotification(ra, stdout, "textDocument/publishDiagnostics", .{
        .uri = uri,
        .diagnostics = diags,
    });
}

/// Publish diagnostics for every document whose debounce deadline has passed.
/// Called from the main loop when poll times out. Uses its own short-lived
/// arena so nothing accumulates between flushes.
pub fn flushDueDiagnostics(server: *state.ServerState, stdout: std.posix.fd_t) void {
    var arena = std.heap.ArenaAllocator.init(server.allocator);
    defer arena.deinit();
    const ra = arena.allocator();

    const due = server.collectDueDiagnostics(ra, std.time.milliTimestamp()) catch return;
    for (due) |uri| {
        publishDiagnostics(server, stdout, ra, uri) catch {};
    }
}

const DiagRange = struct {
    start: struct { line: u32, character: u32 },
    end: struct { line: u32, character: u32 },
};
const DiagObj = struct {
    range: DiagRange,
    severity: u32,
    message: []const u8,
};

pub fn handleMessage(server: *state.ServerState, stdout: std.posix.fd_t, body: []const u8) !void {
    // Per-request arena: all JSON parsing and response formatting lives here
    // and is freed before the next message is read.
    var request_arena = std.heap.ArenaAllocator.init(server.allocator);
    defer request_arena.deinit();
    const ra = request_arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, ra, body, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const method = root.object.get("method");
    const id = root.object.get("id");
    const params = root.object.get("params");

    if (method == null or method.? != .string) return;
    const method_str = method.?.string;

    dispatch(server, stdout, ra, method_str, id, params) catch |err| {
        // Never let a single bad request kill the server. Requests (with an
        // id) get an internal-error response; notifications fail silently.
        if (id != null) {
            transport.sendError(ra, stdout, id.?, InternalError, @errorName(err)) catch {};
        }
    };
}

fn dispatch(
    server: *state.ServerState,
    stdout: std.posix.fd_t,
    ra: std.mem.Allocator,
    method_str: []const u8,
    id: ?std.json.Value,
    params: ?std.json.Value,
) !void {
    if (std.mem.eql(u8, method_str, "initialize")) {
        if (id != null) {
            try transport.sendResponse(ra, stdout, id.?, .{
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
            try transport.sendResponse(ra, stdout, id.?, null);
        }
    } else if (std.mem.eql(u8, method_str, "exit")) {
        std.posix.exit(0);
    } else if (std.mem.eql(u8, method_str, "textDocument/didOpen")) {
        try handleDidOpen(server, stdout, ra, params);
    } else if (std.mem.eql(u8, method_str, "textDocument/didChange")) {
        try handleDidChange(server, stdout, ra, params);
    } else if (std.mem.eql(u8, method_str, "textDocument/didClose")) {
        try handleDidClose(server, stdout, ra, params);
    } else if (std.mem.eql(u8, method_str, "textDocument/hover")) {
        try handleHover(server, stdout, ra, id, params);
    } else if (std.mem.eql(u8, method_str, "textDocument/definition")) {
        try handleDefinition(server, stdout, ra, id, params);
    } else if (id != null) {
        // Unknown *request*: must answer or clients can hang.
        try transport.sendError(ra, stdout, id.?, MethodNotFound, "Method not found");
    }
    // Unknown notifications (no id, incl. $/...) are ignored per spec.
}

fn handleDidOpen(server: *state.ServerState, stdout: std.posix.fd_t, ra: std.mem.Allocator, params: ?std.json.Value) !void {
    const textDoc = getObject(params, "textDocument") orelse return;
    const uri = getString(textDoc, "uri") orelse return;
    const text = getString(textDoc, "text") orelse return;
    try server.updateDocument(uri, text, null);
    try publishDiagnostics(server, stdout, ra, uri);
}

fn handleDidChange(server: *state.ServerState, stdout: std.posix.fd_t, ra: std.mem.Allocator, params: ?std.json.Value) !void {
    // stdout is unused here: publishing is debounced via the main loop.
    _ = stdout;
    const textDoc = getObject(params, "textDocument") orelse return;
    const uri = getString(textDoc, "uri") orelse return;
    const version: ?i32 = if (textDoc.get("version")) |v|
        (if (v == .integer) @as(i32, @intCast(v.integer)) else null)
    else
        null;

    const changes = params.?.object.get("contentChanges") orelse return;
    if (changes != .array) return;

    var current: []const u8 = server.getDocument(uri) orelse "";
    current = try ra.dupe(u8, current);

    for (changes.array.items) |change| {
        if (change != .object) continue;
        const text = getString(change.object, "text") orelse continue;
        if (change.object.get("range")) |range| {
            if (range != .object) continue;
            const start = getPos(range.object.get("start")) orelse continue;
            const end = getPos(range.object.get("end")) orelse continue;
            const s = lineCharToOffset(current, start.line, start.character) orelse continue;
            const e = lineCharToOffset(current, end.line, end.character) orelse continue;
            if (e < s) continue;
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(ra, current[0..s]);
            try out.appendSlice(ra, text);
            try out.appendSlice(ra, current[e..]);
            current = out.items;
        } else {
            // Full sync: change replaces the whole document.
            current = text;
        }
    }

    try server.updateDocument(uri, current, version);
    // Trailing debounce: let rapid keystrokes settle before re-running
    // diagnostics. The main loop flushes due publishes when poll times out.
    try server.scheduleDiagnostics(uri, std.time.milliTimestamp());
}

fn handleDidClose(server: *state.ServerState, stdout: std.posix.fd_t, ra: std.mem.Allocator, params: ?std.json.Value) !void {
    const textDoc = getObject(params, "textDocument") orelse return;
    const uri = getString(textDoc, "uri") orelse return;
    // Clear stale diagnostics in the editor, then drop the document.
    try transport.sendNotification(ra, stdout, "textDocument/publishDiagnostics", .{
        .uri = uri,
        .diagnostics = @as([]const DiagObj, &.{}),
    });
    server.removeDocument(uri);
}

fn handleHover(server: *state.ServerState, stdout: std.posix.fd_t, ra: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value) !void {
    if (id == null) return;

    var hover_value: []const u8 = "No basic type info found.";

    const textDoc = getObject(params, "textDocument");
    const pos = getObject(params, "position");

    if (textDoc != null and pos != null) {
        const uri = getString(textDoc.?, "uri");
        const line_val = pos.?.get("line");
        const char_val = pos.?.get("character");

        if (uri != null and line_val != null and line_val.? == .integer and char_val != null and char_val.? == .integer) {
            const target_line = @as(u32, @intCast(line_val.?.integer)) + 1;
            const target_col = @as(u32, @intCast(char_val.?.integer)) + 1;

            if (server.ensureAnalysis(uri.?)) |analysis| {
                hover_value = computeHover(ra, analysis, target_line, target_col) orelse hover_value;
            } else |_| {}
        }
    }

    try transport.sendResponse(ra, stdout, id.?, .{
        .contents = .{
            .kind = "markdown",
            .value = hover_value,
        },
    });
}

fn computeHover(ra: std.mem.Allocator, analysis: anytype, target_line: u32, target_col: u32) ?[]const u8 {
    const tokens = analysis.scan.tokens.items;
    for (tokens) |t| {
        if (t.line != target_line) continue;
        const end_col = t.column + @as(u32, @intCast(t.value.len)); // exclusive
        if (target_col < t.column or target_col >= end_col) continue;

        if (t.type == .delimiter or t.type == .bin_op or t.type == .unary_op or t.type == .assign_op or t.type == .keyword or t.type == .eof) {
            return null;
        }

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
                type_str = "[]byte";
                prefix = "(literal) ";
            },
            .v_register, .identifier => {
                var is_const = false;
                var is_func = false;
                var is_type = false;

                const doc = &analysis.doc;
                const cs = analysis.typecheck_state;

                if (infer.findDeclarationInAst(doc, t.value)) |decl_node| {
                    if (decl_node.* == .declaration) is_const = decl_node.declaration.is_const;
                    if (decl_node.* == .function_decl) is_func = true;
                    if (decl_node.* == .type_decl or decl_node.* == .struct_decl or decl_node.* == .enum_decl or decl_node.* == .error_decl) is_type = true;
                    // formatType is degenerate for some decl shapes (struct
                    // inits -> null, bare-name values -> just the value name);
                    // the typechecker's recorded display type is authoritative.
                    const fmt_type = infer.formatType(ra, decl_node, false, doc);
                    var weak = false;
                    if (decl_node.* == .declaration) {
                        const d = decl_node.declaration;
                        if (d.type_annotation == null and (d.value.* == .struct_init or d.value.* == .primary)) weak = true;
                    }
                    if (fmt_type != null and !weak) {
                        type_str = fmt_type.?;
                    } else if (cs) |state_ptr| {
                        if (state_ptr.global_types.get(t.value)) |gt| {
                            type_str = ra.dupe(u8, gt) catch "unknown";
                        } else if (fmt_type) |ft| {
                            type_str = ft;
                        }
                    } else if (fmt_type) |ft| {
                        type_str = ft;
                    }
                } else if (infer.findVariantSiteInDoc(doc, t.value, t.line)) |site| {
                    // Decl-site variant (`Red,` inside `@enum Color { … }`):
                    // variants are not declaration nodes, so resolve through
                    // the enclosing decl's variant list.
                    switch (site.decl_kind) {
                        .enum_decl => {
                            var val: i32 = 0;
                            var str_val: ?[]const u8 = null;
                            if (cs) |state_ptr| {
                                if (state_ptr.enums.get(site.type_name)) |ed| {
                                    if (ed.variants.get(site.variant)) |v| val = v;
                                    if (ed.string_values) |*sv| {
                                        if (sv.get(site.variant)) |s| str_val = s;
                                    }
                                }
                            }
                            if (str_val) |s| {
                                type_str = std.fmt.allocPrint(ra, "(@enum {s}) {s} = \"{s}\"", .{ site.type_name, site.variant, s }) catch "unknown";
                            } else {
                                type_str = std.fmt.allocPrint(ra, "(@enum {s}) {s} = {d}", .{ site.type_name, site.variant, val }) catch "unknown";
                            }
                        },
                        .error_decl => {
                            type_str = std.fmt.allocPrint(ra, "(@error {s}) {s}", .{ site.type_name, site.variant }) catch "unknown";
                        },
                    }
                } else if (cs) |state_ptr| {
                    if (infer.findPrimaryInDoc(doc, t.line, t.column)) |primary_node| {
                        var resolved: ?[]const u8 = if (state_ptr.type_of_results.get(primary_node)) |rt|
                            (if (std.mem.eql(u8, rt, "unknown")) null else rt)
                        else
                            null;
                        // Forward-referenced members (e.g. `p.x = …` inside a
                        // function body — functions are checked before top-level
                        // decls register) have no *usable* recorded type (the
                        // inference saw an unresolved object and wrote `unknown`).
                        // Derive the field type from the object's global type +
                        // struct layout.
                        if (resolved == null and primary_node.* == .member and
                            primary_node.member.object.* == .primary and
                            primary_node.member.property.* == .primary)
                        {
                            const obj_name = primary_node.member.object.primary.name;
                            var obj_type: ?[]const u8 = state_ptr.global_types.get(obj_name);
                            if (obj_type == null) {
                                var key_buf: [256]u8 = undefined;
                                if (std.fmt.bufPrint(&key_buf, "${s}", .{obj_name})) |key| {
                                    obj_type = state_ptr.global_types.get(key);
                                } else |_| {}
                            }
                            if (obj_type) |ot| {
                                if (state_ptr.structs.get(ot)) |sd| {
                                    if (sd.types.get(primary_node.member.property.primary.name)) |ft| {
                                        resolved = ft;
                                    }
                                }
                            }
                        }
                        if (resolved) |resolved_type| {
                            if (primary_node.* == .member and state_ptr.enums.contains(resolved_type) and primary_node.member.property.* == .primary) {
                                const enum_name = resolved_type;
                                const variant_name = primary_node.member.property.primary.name;
                                var val: i32 = 0;
                                var str_val: ?[]const u8 = null;
                                if (state_ptr.enums.get(enum_name)) |ed| {
                                    if (ed.variants.get(variant_name)) |v| val = v;
                                    if (ed.string_values) |*sv| {
                                        if (sv.get(variant_name)) |s| str_val = s;
                                    }
                                }
                                if (str_val) |s| {
                                    type_str = std.fmt.allocPrint(ra, "(@enum {s}) {s} = \"{s}\"", .{ enum_name, variant_name, s }) catch "unknown";
                                } else {
                                    type_str = std.fmt.allocPrint(ra, "(@enum {s}) {s} = {d}", .{ enum_name, variant_name, val }) catch "unknown";
                                }
                            } else if (primary_node.* == .member and state_ptr.error_sets.contains(resolved_type) and primary_node.member.property.* == .primary) {
                                const member_name = primary_node.member.property.primary.name;
                                type_str = std.fmt.allocPrint(ra, "(@error {s}) {s}", .{ resolved_type, member_name }) catch "unknown";
                            } else {
                                type_str = ra.dupe(u8, resolved_type) catch "unknown";
                            }
                        }
                    }
                }

                if (is_func or is_type) {
                    prefix = "";
                } else if (is_const) {
                    prefix = "@const ";
                } else {
                    prefix = "";
                }
            },
            .compiler_keyword => {
                type_str = "intrinsic";
                prefix = "(builtin) ";
            },
            else => {},
        }

        var inner: []const u8 = "";
        if (std.mem.startsWith(u8, type_str, "@func ") or
            std.mem.startsWith(u8, type_str, "@struct ") or
            std.mem.startsWith(u8, type_str, "@enum ") or
            std.mem.startsWith(u8, type_str, "@error ") or
            std.mem.startsWith(u8, type_str, "@type ") or
            std.mem.startsWith(u8, type_str, "(@enum ") or
            std.mem.startsWith(u8, type_str, "(@error ") or
            std.mem.startsWith(u8, type_str, "(struct field)"))
        {
            inner = type_str;
        } else {
            inner = std.fmt.allocPrint(ra, "{s}{s}: {s}", .{ prefix, t.value, type_str }) catch return null;
        }

        return wrapCode(ra, inner);
    }
    return null;
}

/// Test shim: run computeHover over a fully-built Analysis at 1-based token
/// coordinates (same coordinate space computeHover takes). The caller supplies
/// the allocator and owns any returned memory.
pub fn computeHoverForTest(analysis: anytype, allocator: std.mem.Allocator, target_line: u32, target_col: u32) ?[]const u8 {
    return computeHover(allocator, analysis, target_line, target_col);
}

/// Wrap hover content in an llts code fence, widening the fence when the
/// content itself contains backtick runs (CommonMark closing-fence rule),
/// so messages that quote code can't break out of the block.
fn wrapCode(ra: std.mem.Allocator, content: []const u8) []const u8 {
    var max_run: usize = 0;
    var run: usize = 0;
    for (content) |c| {
        if (c == '`') {
            run += 1;
            if (run > max_run) max_run = run;
        } else {
            run = 0;
        }
    }
    // Standard fence is three backticks; widen when the content contains a
    // backtick run that would close it (CommonMark closing-fence rule).
    var fence_buf: [16]u8 = undefined;
    @memset(&fence_buf, '`');
    const wanted: usize = if (max_run + 1 > 3) max_run + 1 else 3;
    const fence = fence_buf[0..@min(wanted, fence_buf.len)];
    return std.fmt.allocPrint(ra, "{s}llts\n{s}\n{s}", .{ fence, content, fence }) catch content;
}

fn handleDefinition(server: *state.ServerState, stdout: std.posix.fd_t, ra: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value) !void {
    if (id == null) return;

    const textDoc = getObject(params, "textDocument");
    const pos = getObject(params, "position");

    if (textDoc != null and pos != null) {
        const uri = getString(textDoc.?, "uri");
        const line_val = pos.?.get("line");
        const char_val = pos.?.get("character");

        if (uri != null and line_val != null and line_val.? == .integer and char_val != null and char_val.? == .integer) {
            const target_line = @as(u32, @intCast(line_val.?.integer)) + 1;
            const target_col = @as(u32, @intCast(char_val.?.integer)) + 1;

            if (server.ensureAnalysis(uri.?)) |analysis| {
                if (findDefinition(analysis, target_line, target_col)) |decl| {
                    try transport.sendResponse(ra, stdout, id.?, .{
                        .uri = uri.?,
                        .range = .{
                            .start = .{
                                .line = decl.line - 1,
                                .character = decl.column - 1,
                            },
                            .end = .{
                                .line = decl.line - 1,
                                .character = decl.column - 1 + @as(i64, @intCast(decl.len)),
                            },
                        },
                    });
                    return;
                }
            } else |_| {}
        }
    }

    try transport.sendResponse(ra, stdout, id.?, null);
}

/// AST-based resolution (params, shadowing, forward refs) with the old
/// token heuristic as a fallback for files that fail to parse.
fn findDefinition(analysis: anytype, target_line: u32, target_col: u32) ?struct { line: u32, column: u32, len: usize } {
    // 1. Locate the token under the cursor; only names are resolvable.
    const tokens = analysis.scan.tokens.items;
    var target_name: ?[]const u8 = null;
    for (tokens) |t| {
        if (t.line != target_line) continue;
        const end_col = t.column + @as(u32, @intCast(t.value.len));
        if (target_col >= t.column and target_col <= end_col) {
            if (t.type == .identifier or t.type == .v_register) {
                target_name = t.value;
            }
            break;
        }
    }
    const name = target_name orelse return null;

    // 2. Resolve through the AST when the document parses.
    if (resolve.resolveDefinition(&analysis.doc, name, target_line, target_col)) |loc| {
        return .{ .line = loc.line, .column = loc.column, .len = name.len };
    }

    // 3. Fallback: token heuristic for unparseable documents.
    if (findDeclToken(analysis, target_line, target_col)) |tok| {
        return .{ .line = tok.line, .column = tok.column, .len = tok.value.len };
    }
    return null;
}

fn findDeclToken(analysis: anytype, target_line: u32, target_col: u32) ?llts.scanner.Token {
    const tokens = analysis.scan.tokens.items;

    // 1. Find the name we are going to definition on.
    var target_name: ?[]const u8 = null;
    var is_register = false;

    for (tokens) |t| {
        if (t.line != target_line) continue;
        const end_col = t.column + @as(u32, @intCast(t.value.len));
        if (target_col >= t.column and target_col <= end_col) {
            if (t.type == .identifier or t.type == .v_register) {
                target_name = t.value;
                is_register = (t.type == .v_register);
            }
            break;
        }
    }

    const name = target_name orelse return null;

    // 2. Scan from the top to find the first declaration.
    for (tokens, 0..) |t, i| {
        if (is_register) {
            // Registers: first LHS of `=` or token after `@const`.
            if (t.type != .v_register or !std.mem.eql(u8, t.value, name)) continue;
            const prev = if (i > 0) tokens[i - 1] else null;
            const next = if (i + 1 < tokens.len) tokens[i + 1] else null;
            const is_const = prev != null and prev.?.type == .compiler_keyword and std.mem.eql(u8, prev.?.value, "const");
            const is_assign = next != null and next.?.type == .assign_op;
            if (is_const or is_assign) return t;
        } else {
            // Identifiers: `@func foo`, `@struct foo`, `@enum foo`, etc.
            if (t.type != .identifier or !std.mem.eql(u8, t.value, name)) continue;
            const prev = if (i > 0) tokens[i - 1] else null;
            if (prev == null or prev.?.type != .compiler_keyword) continue;
            const kw = prev.?.value;
            if (std.mem.eql(u8, kw, "func") or
                std.mem.eql(u8, kw, "struct") or
                std.mem.eql(u8, kw, "enum") or
                std.mem.eql(u8, kw, "type") or
                std.mem.eql(u8, kw, "error"))
            {
                return t;
            }
        }
    }
    return null;
}

// --- JSON helpers ----------------------------------------------------------

fn getObject(v: ?std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (v == null or v.? != .object) return null;
    const field = v.?.object.get(key) orelse return null;
    if (field != .object) return null;
    return field.object;
}

fn getString(v: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const field = v.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

const Position = struct { line: u32, character: u32 };

fn getPos(v: ?std.json.Value) ?Position {
    const obj = getObject(v, "") orelse {
        if (v == null or v.? != .object) return null;
        return getPosFields(v.?.object);
    };
    return getPosFields(obj);
}

fn getPosFields(obj: std.json.ObjectMap) ?Position {
    const line_val = obj.get("line") orelse return null;
    const char_val = obj.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;
    if (line_val.integer < 0 or char_val.integer < 0) return null;
    return .{
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
    };
}

/// Map a 0-based line/character position to a byte offset, clamping the
/// character to the line length. Returns null when the line is out of range.
fn lineCharToOffset(text: []const u8, line: u32, character: u32) ?usize {
    var cur_line: u32 = 0;
    var i: usize = 0;
    while (cur_line < line) : (cur_line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return null;
        i = nl + 1;
    }
    const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
    const line_len: u32 = @intCast(line_end - i);
    return i + @min(character, line_len);
}
