const std = @import("std");
const ctx = @import("ctx.zig");
const tokens = @import("tokens.zig");
const report = @import("../errors/report.zig");

fn fail(self: *ctx.Scanner, err: ctx.ScanError, message: []const u8) ctx.ScanError {
    report.reportSourceErrorWithFrame(self.path, self.source, self.line, self.column, message, "<scan>");
    return err;
}

/// True when `pos` starts a valid closing fence line: optional indent then ``` .
/// Trailing content on that line (e.g. `;`) is left for the normal scanner.
fn looksLikeCloseFence(source: []const u8, pos: usize) bool {
    var i = pos;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i + 3 > source.len) return false;
    return source[i] == '`' and source[i + 1] == '`' and source[i + 2] == '`';
}

const Pos = struct { line: u32, column: u32 };

/// Position of `body[offset]` given body starts at file line `body_line` col 1.
fn posInBody(body: []const u8, offset: usize, body_line: u32) Pos {
    var line: u32 = body_line;
    var col: u32 = 1;
    var i: usize = 0;
    const n = @min(offset, body.len);
    while (i < n) : (i += 1) {
        if (body[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

/// Scan a fenced template starting at the opening ``` .
/// Emits one `.template` token: raw body value + text/hole parts.
pub fn scanTemplate(self: *ctx.Scanner) ctx.ScanError!void {
    const open_line = self.line;
    const open_col = self.column;

    _ = self.advance(); // `
    _ = self.advance();
    _ = self.advance();

    // Opening fence rest-of-line: only spaces/tabs, then newline or EOF.
    while (self.peek(0)) |c| {
        if (c == '\n' or c == '\r') break;
        if (c != ' ' and c != '\t') {
            self.line = open_line;
            self.column = open_col;
            return fail(
                self,
                error.TemplateFence,
                \\expected a newline after the opening ```
                \\
                \\help: a template literal is fenced across lines:
                \\
                \\    ```
                \\    body
                \\    ```;
                \\
                \\note: ``` sharing a line with other code is not a fence — use a normal "…" string
            );
        }
        _ = self.advance();
    }

    if (self.peek(0) == null) {
        self.line = open_line;
        self.column = open_col;
        return fail(
            self,
            error.UnterminatedTemplate,
            \\unterminated template literal
            \\
            \\help: close the template with ``` on its own line:
            \\
            \\    ```
            \\    text
            \\    ```;
            \\
            \\note: after the closing ``` you still write `;` like any expression
        );
    }

    // Consume the newline that begins the body.
    if (self.peek(0) == '\r' and self.peek(1) == '\n') {
        _ = self.advance();
        _ = self.advance();
    } else if (self.peek(0) == '\n') {
        _ = self.advance();
    }

    const body_start = self.pos;
    var at_line_start = true;
    var close_line_start: usize = body_start;
    var found_close = false;

    while (self.pos < self.source.len) {
        if (at_line_start and looksLikeCloseFence(self.source, self.pos)) {
            close_line_start = self.pos;
            // Consume indent + ``` only; leave `;` / trailing tokens for scanNext.
            while (self.peek(0)) |c| {
                if (c != ' ' and c != '\t') break;
                _ = self.advance();
            }
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
            found_close = true;
            break;
        }
        const c = self.advance();
        at_line_start = (c == '\n');
    }

    if (!found_close) {
        self.line = open_line;
        self.column = open_col;
        return fail(
            self,
            error.UnterminatedTemplate,
            \\unterminated template literal
            \\
            \\help: every opening ``` needs a closing ``` on its own line:
            \\
            \\    ```
            \\    text
            \\    ```;
            \\
            \\note: a line that is only optional spaces + ``` closes the template; ``` mid-line does not
        );
    }

    var body_end = close_line_start;
    if (body_end > body_start) {
        if (self.source[body_end - 1] == '\n') {
            body_end -= 1;
            if (body_end > body_start and self.source[body_end - 1] == '\r') body_end -= 1;
        } else if (self.source[body_end - 1] == '\r') {
            body_end -= 1;
        }
    }

    const body = self.source[body_start..body_end];
    const body_line = open_line + 1;
    const owned_body = self.allocator.dupe(u8, body) catch return error.OutOfMemory;
    errdefer self.allocator.free(owned_body);

    var parts: std.ArrayList(tokens.TemplatePart) = .empty;
    defer {
        for (parts.items) |p| self.allocator.free(p.value);
        parts.deinit(self.allocator);
    }

    try splitTemplateParts(self, body, body_line, open_line, &parts);

    const owned_parts = parts.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    parts = .empty;

    try self.pushTemplateToken(owned_body, owned_parts, open_col, open_line);
}

fn splitTemplateParts(
    self: *ctx.Scanner,
    body: []const u8,
    body_line: u32,
    open_line: u32,
    out: *std.ArrayList(tokens.TemplatePart),
) ctx.ScanError!void {
    var text_start: usize = 0;
    var i: usize = 0;

    while (i < body.len) {
        if (body[i] == '\\' and i + 1 < body.len) {
            i += 2;
            continue;
        }
        if (body[i] == '$' and i + 1 < body.len and body[i + 1] == '{') {
            if (i > text_start) {
                const raw = body[text_start..i];
                const owned = self.allocator.dupe(u8, raw) catch return error.OutOfMemory;
                const p = posInBody(body, text_start, body_line);
                try out.append(self.allocator, .{
                    .is_hole = false,
                    .value = owned,
                    .line = p.line,
                    .column = p.column,
                });
            }

            const hole_off = i + 2;
            const hole_pos = posInBody(body, hole_off, body_line);
            i = hole_off;
            var depth: usize = 1;
            while (i < body.len) {
                const c = body[i];
                if (c == '\\') {
                    if (i + 1 < body.len) {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                if (c == '"' or c == '\'') {
                    const q = c;
                    i += 1;
                    while (i < body.len and body[i] != q) {
                        if (body[i] == '\\' and i + 1 < body.len) {
                            i += 2;
                            continue;
                        }
                        i += 1;
                    }
                    if (i < body.len) i += 1;
                    continue;
                }
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                i += 1;
            }
            if (depth != 0 or i >= body.len) {
                self.line = hole_pos.line;
                self.column = hole_pos.column;
                return fail(
                    self,
                    error.UnterminatedTemplate,
                    \\unterminated `${…}` interpolation
                    \\
                    \\help: close every interpolation with `}`:
                    \\
                    \\    ```
                    \\    hello ${name}
                    \\    ```;
                    \\
                    \\note: a hole is a single expression; `$name = …` declarations are not allowed inside ${}
                );
            }
            const hole_src = body[hole_off..i];
            const owned_hole = self.allocator.dupe(u8, hole_src) catch return error.OutOfMemory;
            try out.append(self.allocator, .{
                .is_hole = true,
                .value = owned_hole,
                .line = hole_pos.line,
                .column = hole_pos.column,
            });
            i += 1;
            text_start = i;
            continue;
        }
        i += 1;
    }

    if (text_start < body.len) {
        const raw = body[text_start..];
        const owned = self.allocator.dupe(u8, raw) catch return error.OutOfMemory;
        const p = posInBody(body, text_start, body_line);
        try out.append(self.allocator, .{
            .is_hole = false,
            .value = owned,
            .line = p.line,
            .column = p.column,
        });
    }

    if (out.items.len == 0) {
        const owned = self.allocator.dupe(u8, "") catch return error.OutOfMemory;
        try out.append(self.allocator, .{
            .is_hole = false,
            .value = owned,
            .line = open_line,
            .column = 1,
        });
    }
}
