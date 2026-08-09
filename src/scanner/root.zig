const std = @import("std");
const tokens = @import("tokens.zig");
const keywords = @import("keywords.zig");
const numbers = @import("numbers.zig");
const strings = @import("strings.zig");
const ctx = @import("ctx.zig");
const ops = @import("../shared/ops.zig");

pub const Token = tokens.Token;
pub const TokenType = tokens.TokenType;
pub const ScanResult = tokens.ScanResult;
pub const ScanError = ctx.ScanError;
pub const ScannerCtx = ctx.Scanner;
pub const isDigitFn = ctx.isDigit;

pub fn scan(allocator: std.mem.Allocator, source: []const u8, path: []const u8) ScanError!ScanResult {
    var sc: ctx.Scanner = .{
        .source = source,
        .path = path,
        .allocator = allocator,
    };
    try scanAll(&sc);
    return .{ .tokens = sc.tokens, .allocator = allocator };
}

pub fn deinitScanResult(result: *ScanResult) void {
    for (result.tokens.items) |t| {
        result.allocator.free(t.value);
    }
    result.tokens.deinit(result.allocator);
}

fn scanAll(self: *ctx.Scanner) ScanError!void {
    while (self.pos < self.source.len) {
        try scanNext(self);
    }
    try self.pushToken(.eof, "", self.column, self.line);
}

fn scanNext(self: *ctx.Scanner) ScanError!void {
    const ch = self.peek(0) orelse return;
    if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
        _ = self.advance();
        return;
    }
    if (ch == '#') {
        while (self.peek(0)) |c| {
            if (c == '\n') break;
            _ = self.advance();
        }
        return;
    }
    if (ch == '"' or ch == '\'') {
        try strings.scanString(self);
        return;
    }
    if (ch == '$') {
        try scanRegister(self);
        if (self.peek(0) == '.') try scanMemberExpression(self);
        return;
    }
    if (ch == '@') {
        try scanCompilerKeyword(self);
        return;
    }
    if (ctx.isDigit(ch)) {
        try numbers.scanNumber(self);
        return;
    }
    if (ctx.isAlpha(ch)) {
        try scanIdentifierOrKeyword(self);
        if (self.peek(0) == '.') try scanMemberExpression(self);
        return;
    }
    if (ch == '.' and self.peek(1) == '.' and self.peek(2) == '.') {
        const col = self.column;
        const line = self.line;
        _ = self.advance();
        _ = self.advance();
        _ = self.advance();
        try self.pushToken(.delimiter, "...", col, line);
        return;
    }

    if (self.peek(1)) |c2| {
        var two: [2]u8 = .{ ch, c2 };
        if (ops.isAssignOp(two[0..])) {
            const col = self.column;
            const line = self.line;
            _ = self.advance();
            _ = self.advance();
            try self.pushToken(.assign_op, two[0..], col, line);
            return;
        }
        if (ops.isBinOp(two[0..])) {
            const col = self.column;
            const line = self.line;
            _ = self.advance();
            _ = self.advance();
            try self.pushToken(.bin_op, two[0..], col, line);
            return;
        }
    }

    const one = self.source[self.pos .. self.pos + 1];
    if (ops.isAssignOp(one) or ops.isBinOp(one) or ops.isUnaryOp(one)) {
        const col = self.column;
        const line = self.line;
        _ = self.advance();
        const typ: TokenType = if (ops.isBinOp(one))
            .bin_op
        else if (ops.isAssignOp(one))
            .assign_op
        else
            .unary_op;
        try self.pushToken(typ, one, col, line);
        return;
    }

    if (keywords.isDelimiter(ch)) {
        const col = self.column;
        const line = self.line;
        _ = self.advance();
        try self.pushToken(.delimiter, one, col, line);
        return;
    }

    std.debug.print("{s}:{d}:{d}: Unexpected character\n", .{ self.path, self.line, self.column });
    return error.UnexpectedCharacter;
}

fn scanRegister(self: *ctx.Scanner) ScanError!void {
    const col = self.column;
    const line = self.line;
    _ = self.advance();
    const start = self.pos;
    while (self.peek(0)) |c| {
        if (!ctx.isAlphaNumeric(c)) break;
        _ = self.advance();
    }
    if (self.pos == start) return error.ExpectedRegister;
    try self.pushToken(.v_register, self.source[start..self.pos], col, line);
}

fn scanCompilerKeyword(self: *ctx.Scanner) ScanError!void {
    const col = self.column;
    const line = self.line;
    _ = self.advance();
    const start = self.pos;
    while (self.peek(0)) |c| {
        if (!ctx.isAlphaNumeric(c)) break;
        _ = self.advance();
    }
    if (self.pos == start) return error.ExpectedCompilerKeyword;
    const kw = self.source[start..self.pos];
    if (!keywords.isCompilerSymbol(kw)) return error.InvalidCompilerKeyword;
    try self.pushToken(.compiler_keyword, kw, col, line);
}

fn scanIdentifierOrKeyword(self: *ctx.Scanner) ScanError!void {
    const col = self.column;
    const line = self.line;
    const start = self.pos;
    while (self.peek(0)) |c| {
        if (!ctx.isAlphaNumeric(c)) break;
        _ = self.advance();
    }
    const word = self.source[start..self.pos];
    if (word.len == 0) return;
    if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) {
        try self.pushToken(.boolean, word, col, line);
        return;
    }
    const typ: TokenType = if (keywords.isKeyword(word)) .keyword else .identifier;
    try self.pushToken(typ, word, col, line);
}

fn scanMemberExpression(self: *ctx.Scanner) ScanError!void {
    const base = self.previous() orelse return error.InvalidMember;
    if (base.type != .v_register and base.type != .identifier) return error.InvalidMember;
    while (self.peek(0) == '.') {
        const col = self.column;
        const line = self.line;
        _ = self.advance();
        try self.pushToken(.delimiter, ".", col, line);
        const ch = self.peek(0) orelse return error.InvalidMember;
        if (!ctx.isAlphaNumeric(ch)) return error.InvalidMember;
        try scanIdentifierOrKeyword(self);
    }
}

test "scan integers and registers" {
    const src = "$x = 42\n";
    var result = try scan(std.testing.allocator, src, "t.lls");
    defer deinitScanResult(&result);
    try std.testing.expect(result.tokens.items.len >= 4);
    try std.testing.expect(result.tokens.items[0].type == .v_register);
    try std.testing.expectEqualStrings("x", result.tokens.items[0].value);
}

test "scan hex binary octal" {
    var result = try scan(std.testing.allocator, "0xFF 0b1010 0o77", "t.lls");
    defer deinitScanResult(&result);
    try std.testing.expect(result.tokens.items[0].type == .hex);
    try std.testing.expect(result.tokens.items[1].type == .binary);
    try std.testing.expect(result.tokens.items[2].type == .octal);
}

test "scan compiler keywords" {
    var result = try scan(std.testing.allocator, "@func @if @for", "t.lls");
    defer deinitScanResult(&result);
    try std.testing.expect(result.tokens.items[0].type == .compiler_keyword);
    try std.testing.expectEqualStrings("func", result.tokens.items[0].value);
}
