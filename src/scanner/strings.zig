const std = @import("std");
const ctx = @import("ctx.zig");
const report = @import("../errors/report.zig");

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn fail(self: *ctx.Scanner, quote: u8, err: ctx.ScanError, message: []const u8) ctx.ScanError {
    report.reportSourceErrorWithFrame(self.path, self.source, self.line, self.column, message, "<scan>");
    while (self.peek(0)) |c| {
        if (c == quote or c == '\n') break;
        _ = self.advance();
    }
    if (self.peek(0)) |c| {
        if (c == quote) _ = self.advance();
    }
    return err;
}

pub fn scanString(self: *ctx.Scanner) ctx.ScanError!void {
    const quote = self.advance();
    const col = self.column - 1;
    const line = self.line;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    while (self.peek(0)) |c| {
        if (c == quote) break;
        if (c == '\n') return fail(self, quote, error.MultilineString, "Multiline strings are not supported; write '\\n' escapes instead");
        if (c == '\\') {
            _ = self.advance();
            const esc = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated string literal; add a closing quote");
            _ = self.advance();
            switch (esc) {
                'a' => try buf.append(self.allocator, 0x07),
                'b' => try buf.append(self.allocator, 0x08),
                'e' => try buf.append(self.allocator, 0x1B),
                'f' => try buf.append(self.allocator, 0x0C),
                'n' => try buf.append(self.allocator, '\n'),
                'r' => try buf.append(self.allocator, '\r'),
                't' => try buf.append(self.allocator, '\t'),
                'v' => try buf.append(self.allocator, 0x0B),
                '\\' => try buf.append(self.allocator, '\\'),
                '"' => try buf.append(self.allocator, '"'),
                '\'' => try buf.append(self.allocator, '\''),
                '$' => try buf.append(self.allocator, '$'),
                'x' => {
                    const c0 = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated hex escape sequence; expected 2 hex digits");
                    const h0 = hexVal(c0) orelse return fail(self, quote, error.InvalidEscapeSequence, "Invalid hex escape sequence '\\xNN'; expected 2 hex digits");
                    _ = self.advance();
                    const c1 = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated hex escape sequence; expected 2 hex digits");
                    const h1 = hexVal(c1) orelse return fail(self, quote, error.InvalidEscapeSequence, "Invalid hex escape sequence '\\xNN'; expected 2 hex digits");
                    _ = self.advance();
                    try buf.append(self.allocator, (@as(u8, h0) << 4) | h1);
                },
                'u' => {
                    var cp: u32 = 0;
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        const ch = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated Unicode escape sequence; expected 4 hex digits");
                        const h = hexVal(ch) orelse return fail(self, quote, error.InvalidEscapeSequence, "Invalid Unicode escape sequence '\\uNNNN'; expected 4 hex digits");
                        _ = self.advance();
                        cp = (cp << 4) | h;
                    }
                    if (cp >= 0xD800 and cp <= 0xDFFF) {
                        return fail(self, quote, error.InvalidEscapeSequence, "Invalid Unicode scalar value in '\\uNNNN' (surrogate halves are not permitted)");
                    }
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch {
                        return fail(self, quote, error.InvalidEscapeSequence, "Failed to encode Unicode code point in '\\uNNNN'");
                    };
                    try buf.appendSlice(self.allocator, utf8_buf[0..len]);
                },
                'U' => {
                    var cp: u32 = 0;
                    var i: usize = 0;
                    while (i < 8) : (i += 1) {
                        const ch = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated Unicode escape sequence; expected 8 hex digits");
                        const h = hexVal(ch) orelse return fail(self, quote, error.InvalidEscapeSequence, "Invalid Unicode escape sequence '\\UNNNNNNNN'; expected 8 hex digits");
                        _ = self.advance();
                        cp = (cp << 4) | h;
                    }
                    if (cp > 0x10FFFF) {
                        return fail(self, quote, error.InvalidEscapeSequence, "Unicode code point out of range in '\\UNNNNNNNN' (maximum is \\U0010FFFF)");
                    }
                    if (cp >= 0xD800 and cp <= 0xDFFF) {
                        return fail(self, quote, error.InvalidEscapeSequence, "Invalid Unicode scalar value in '\\UNNNNNNNN' (surrogate halves are not permitted)");
                    }
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch {
                        return fail(self, quote, error.InvalidEscapeSequence, "Failed to encode Unicode code point in '\\UNNNNNNNN'");
                    };
                    try buf.appendSlice(self.allocator, utf8_buf[0..len]);
                },
                '0'...'7' => {
                    if (esc == '0') {
                        const p0 = self.peek(0);
                        const p1 = self.peek(1);
                        if (p0 == null or !isOctal(p0.?) or p1 == null or !isOctal(p1.?)) {
                            try buf.append(self.allocator, 0);
                            continue;
                        }
                    }
                    const d0: u32 = esc - '0';
                    const c1 = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated octal escape sequence; expected 3 octal digits");
                    if (!isOctal(c1)) return fail(self, quote, error.InvalidEscapeSequence, "Invalid octal escape sequence '\\NNN'; expected 3 octal digits");
                    _ = self.advance();
                    const c2 = self.peek(0) orelse return fail(self, quote, error.UnterminatedString, "Unterminated octal escape sequence; expected 3 octal digits");
                    if (!isOctal(c2)) return fail(self, quote, error.InvalidEscapeSequence, "Invalid octal escape sequence '\\NNN'; expected 3 octal digits");
                    _ = self.advance();

                    const d1: u32 = c1 - '0';
                    const d2: u32 = c2 - '0';
                    const val: u32 = (d0 * 64) + (d1 * 8) + d2;
                    if (val > 255) {
                        return fail(self, quote, error.InvalidEscapeSequence, "Octal escape sequence '\\NNN' out of range (value must be <= 377 in octal / 255)");
                    }
                    try buf.append(self.allocator, @intCast(val));
                },
                else => try buf.append(self.allocator, esc),
            }
            continue;
        }
        try buf.append(self.allocator, c);
        _ = self.advance();
    }
    if (self.peek(0) == null) return fail(self, quote, error.UnterminatedString, "Unterminated string literal; add a closing quote");
    _ = self.advance();
    const final_str = try buf.toOwnedSlice(self.allocator);
    try self.pushToken(.string, final_str, col, line);
}
