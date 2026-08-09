const std = @import("std");
const tokens_mod = @import("../scanner/tokens.zig");
const ast = @import("../ast/root.zig");

pub const Token = tokens_mod.Token;
pub const TokenType = tokens_mod.TokenType;
pub const Node = ast.Node;
pub const Location = ast.Location;
pub const Document = ast.Document;

pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    path: []const u8,
    source: []const u8,
    arena: std.mem.Allocator,

    pub fn peek(self: *const Parser, step: usize) ?Token {
        const i = self.current + step;
        if (i >= self.tokens.len) return null;
        return self.tokens[i];
    }

    pub fn previous(self: *const Parser) ?Token {
        if (self.current == 0) return null;
        return self.tokens[self.current - 1];
    }

    pub fn isAtEnd(self: *const Parser) bool {
        const next = self.peek(0) orelse return true;
        return next.type == .eof;
    }

    pub fn check(self: *const Parser, typ: TokenType) bool {
        if (self.isAtEnd()) return false;
        const next = self.peek(0) orelse return false;
        return next.type == typ;
    }

    pub fn checkDelim(self: *const Parser, value: []const u8) bool {
        const next = self.peek(0) orelse return false;
        return next.type == .delimiter and std.mem.eql(u8, next.value, value);
    }

    pub fn advance(self: *Parser) ?Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    pub fn match(self: *Parser, typ: TokenType) bool {
        if (self.check(typ)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    pub fn consume(
        self: *Parser,
        typ: TokenType,
        message: []const u8,
        value: ?[]const u8,
    ) ParseError!Token {
        if (value) |v| {
            const t = self.peek(0) orelse return self.failMsg(message);
            const ok = (std.mem.eql(u8, t.value, v) and self.check(typ)) or t.type == .eof;
            if (!ok) return self.failTok(t, "{s}", .{message});
            return self.advance() orelse return error.ParseFailed;
        }
        if (self.check(typ)) {
            return self.advance() orelse return error.ParseFailed;
        }
        const next = self.peek(0) orelse return self.failMsg(message);
        return self.failTok(next, "{s}", .{message});
    }

    pub fn failTok(self: *Parser, token: Token, comptime fmt: []const u8, args: anytype) ParseError {
        var msg_buf: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch "parse error";
        const report = @import("../errors/report.zig");
        report.reportSourceError(self.path, self.source, token.line, token.column, message);
        report.reportLocationFrame(self.path, token.line, "<script>");
        return error.ParseFailed;
    }

    pub fn failMsg(self: *Parser, message: []const u8) ParseError {
        const t = self.peek(0) orelse Token{ .type = .eof, .value = "", .line = 0, .column = 0 };
        return self.failTok(t, "{s}", .{message});
    }

    pub fn rejectRegisterSigil(self: *Parser, token: Token, next: ?Token) ParseError {
        const name = token.value;
        if (next) |n| {
            if (n.type == .assign_op) {
                return self.failTok(token, "'$' is only used in declarations (@const $name / $name = ...); write '{s} {s} ...' without '$'", .{ name, n.value });
            }
        }
        return self.failTok(token, "'$' is only used in declarations (@const $name / $name = ...); write '{s}' without '$'", .{name});
    }

    pub fn locOf(self: *const Parser, token: Token) Location {
        _ = self;
        return .{ .line = token.line, .column = token.column };
    }

    pub fn dupe(self: *Parser, s: []const u8) ParseError![]const u8 {
        return self.arena.dupe(u8, s) catch return error.OutOfMemory;
    }

    pub fn create(self: *Parser, node: Node) ParseError!*Node {
        const n = self.arena.create(Node) catch return error.OutOfMemory;
        n.* = node;
        return n;
    }

    pub fn setPublic(node: *Node) void {
        switch (node.*) {
            .struct_decl => |*s| s.is_public = true,
            .function_decl => |*f| f.is_public = true,
            .declaration => |*d| d.is_public = true,
            .extern_decl => |*e| e.is_public = true,
            else => {},
        }
    }
};
