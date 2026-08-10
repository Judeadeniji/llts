const ctx = @import("ctx.zig");

pub fn scanString(self: *ctx.Scanner) ctx.ScanError!void {
    const quote = self.advance();
    const col = self.column - 1;
    const line = self.line;
    var buf: @import("std").ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    while (self.peek(0)) |c| {
        if (c == quote) break;
        if (c == '\n') return error.MultilineString;
        if (c == '\\') {
            _ = self.advance();
            const esc = self.peek(0) orelse return error.UnterminatedString;
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
    if (self.peek(0) == null) return error.UnterminatedString;
    _ = self.advance();
    try self.pushToken(.string, buf.items, col, line);
}
