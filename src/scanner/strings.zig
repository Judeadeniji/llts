const ctx = @import("ctx.zig");

pub fn scanString(self: *ctx.Scanner) ctx.ScanError!void {
    const quote = self.advance();
    const col = self.column - 1;
    const line = self.line;
    const start = self.pos;
    while (self.peek(0)) |c| {
        if (c == quote) break;
        if (c == '\n') return error.MultilineString;
        _ = self.advance();
    }
    if (self.peek(0) == null) return error.UnterminatedString;
    const value = self.source[start..self.pos];
    _ = self.advance();
    try self.pushToken(.string, value, col, line);
}
