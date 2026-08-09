const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const expr = @import("expr.zig");
const decl = @import("decl.zig");
const control = @import("control.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseStatement(self: *Parser) ParseError!*Node {
    const token = self.peek(0) orelse return self.failMsg("Unexpected end of input");

    switch (token.type) {
        .v_register => {
            const next = self.peek(1);
            if (next) |n| {
                if (n.type == .assign_op and std.mem.eql(u8, n.value, "="))
                    return decl.parseDeclaration(self, false);
                if (n.type == .delimiter and std.mem.eql(u8, n.value, ":"))
                    return decl.parseDeclaration(self, false);
            }
            return self.rejectRegisterSigil(token, next);
        },
        .bin_op, .unary_op, .assign_op, .identifier => {
            if (self.peek(1)) |n| {
                if (n.type == .delimiter and std.mem.eql(u8, n.value, ":")) {
                    const label_tok = self.advance() orelse return error.ParseFailed;
                    _ = self.advance(); // ':'
                    const s = try parseStatement(self);
                    if (s.* == .for_expr) {
                        s.for_expr.label = try self.dupe(label_tok.value);
                    }
                    return s;
                }
            }
            return parseExpressionStatement(self);
        },
        .string, .number, .hex, .binary, .octal, .boolean => return parseExpressionStatement(self),
        .keyword => {
            if (std.mem.eql(u8, token.value, "pub")) {
                _ = self.advance();
                const s = try parseStatement(self);
                Parser.setPublic(s);
                return s;
            }
            if (std.mem.eql(u8, token.value, "return")) return control.parseReturnStatement(self);
            if (std.mem.eql(u8, token.value, "break")) return control.parseBreakStatement(self);
            if (std.mem.eql(u8, token.value, "continue")) return control.parseContinueStatement(self);
            if (std.mem.eql(u8, token.value, "defer")) return control.parseDeferStatement(self);
            if (std.mem.eql(u8, token.value, "true") or std.mem.eql(u8, token.value, "false") or
                std.mem.eql(u8, token.value, "error") or std.mem.eql(u8, token.value, "null"))
                return parseExpressionStatement(self);
            return self.failTok(token, "Unexpected keyword: {s}", .{token.value});
        },
        .compiler_keyword => return decl.parseCompilerKeyword(self),
        .delimiter => {
            if (std.mem.eql(u8, token.value, "(") or std.mem.eql(u8, token.value, "["))
                return parseExpressionStatement(self);
            return self.failTok(token, "Unexpected token: {s} at line {d}", .{ token.value, token.line });
        },
        else => return self.failTok(token, "Unexpected token: {s} at line {d}", .{ token.value, token.line }),
    }
}

pub fn parseExpressionStatement(self: *Parser) ParseError!*Node {
    const e = try expr.parseExpression(self);
    _ = try self.consume(.delimiter, "Expected ';' after expression", ";");
    return e;
}
