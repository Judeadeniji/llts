const ctx = @import("ctx.zig");

pub fn scanNumber(self: *ctx.Scanner) ctx.ScanError!void {
    const col = self.column;
    const line = self.line;
    const start = self.pos;

    if (self.peek(0) == '0') {
        if (self.peek(1)) |n| {
            if (n == 'x' or n == 'X') {
                _ = self.advance();
                _ = self.advance();
                while (self.peek(0)) |c| {
                    if (!isHex(c)) break;
                    _ = self.advance();
                }
                try self.pushToken(.hex, self.source[start..self.pos], col, line);
                return;
            }
            if (n == 'b' or n == 'B') {
                _ = self.advance();
                _ = self.advance();
                while (self.peek(0)) |c| {
                    if (c != '0' and c != '1') break;
                    _ = self.advance();
                }
                try self.pushToken(.binary, self.source[start..self.pos], col, line);
                return;
            }
            if (n == 'o' or n == 'O') {
                _ = self.advance();
                _ = self.advance();
                while (self.peek(0)) |c| {
                    if (c < '0' or c > '7') break;
                    _ = self.advance();
                }
                try self.pushToken(.octal, self.source[start..self.pos], col, line);
                return;
            }
        }
    }

    while (self.peek(0)) |c| {
        if (!ctx.isDigit(c)) break;
        _ = self.advance();
    }
    if (self.peek(0) == '.') {
        if (self.peek(1)) |d| {
            if (ctx.isDigit(d)) {
                _ = self.advance();
                while (self.peek(0)) |c| {
                    if (!ctx.isDigit(c)) break;
                    _ = self.advance();
                }
            }
        }
    }
    try self.pushToken(.number, self.source[start..self.pos], col, line);
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
