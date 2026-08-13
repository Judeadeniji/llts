const ctx = @import("ctx.zig");
const report = @import("../errors/report.zig");

fn fail(self: *ctx.Scanner, err: ctx.ScanError, message: []const u8) ctx.ScanError {
    report.reportSourceErrorWithFrame(self.path, self.source, self.line, self.column, message, "<scan>");
    return err;
}

pub fn scanString(self: *ctx.Scanner) ctx.ScanError!void {
    const quote = self.advance();
    const col = self.column - 1;
    const line = self.line;
    var buf: @import("std").ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    while (self.peek(0)) |c| {
        if (c == quote) break;
        if (c == '\n') return fail(self, error.MultilineString, "Multiline string literal");
        if (c == '\\') {
            _ = self.advance();
            const esc = self.peek(0) orelse return fail(self, error.UnterminatedString, "Unterminated string");
            switch (esc) {
                'n' => try buf.append(self.allocator, '\n'),
                'r' => try buf.append(self.allocator, '\r'),
                't' => try buf.append(self.allocator, '\t'),
                '\\' => try buf.append(self.allocator, '\\'),
                '"' => try buf.append(self.allocator, '"'),
                '\'' => try buf.append(self.allocator, '\''),
                else => try buf.append(self.allocator, esc),
            }
            _ = self.advance();
            continue;
        }
        try buf.append(self.allocator, c);
        _ = self.advance();
    }
    if (self.peek(0) == null) return fail(self, error.UnterminatedString, "Unterminated string");
    _ = self.advance();
    const final_str = try buf.toOwnedSlice(self.allocator);
    try self.pushToken(.string, final_str, col, line);
}
