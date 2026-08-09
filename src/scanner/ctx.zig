const std = @import("std");
const tokens = @import("tokens.zig");

pub const Token = tokens.Token;
pub const TokenType = tokens.TokenType;
pub const ScanError = error{
    UnexpectedCharacter,
    UnterminatedString,
    MultilineString,
    ExpectedType,
    ExpectedRegister,
    ExpectedCompilerKeyword,
    InvalidCompilerKeyword,
    InvalidMember,
    OutOfMemory,
};

pub const Scanner = struct {
    source: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    pos: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    tokens: std.ArrayList(Token) = .empty,

    pub fn peek(self: *const Scanner, step: usize) ?u8 {
        const i = self.pos + step;
        if (i >= self.source.len) return null;
        return self.source[i];
    }

    pub fn advance(self: *Scanner) u8 {
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return ch;
    }

    pub fn pushToken(self: *Scanner, typ: TokenType, value: []const u8, col: u32, line: u32) !void {
        const owned = try self.allocator.dupe(u8, value);
        try self.tokens.append(self.allocator, .{
            .type = typ,
            .value = owned,
            .line = line,
            .column = col,
        });
    }

    pub fn previous(self: *const Scanner) ?Token {
        if (self.tokens.items.len == 0) return null;
        return self.tokens.items[self.tokens.items.len - 1];
    }
};

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
pub fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
pub fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}
