const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const precedence = @import("../shared/precedence.zig");
const types = @import("types.zig");
const control = @import("control.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseExpression(self: *Parser) ParseError!*Node {
    return parseAssignment(self);
}

fn parseAssignment(self: *Parser) ParseError!*Node {
    const left = try parseBinary(self, 0);
    const tok = self.peek(0) orelse return left;
    if (tok.type == .assign_op) {
        _ = self.advance();
        const right = try parseAssignment(self);
        return self.create(.{ .assignment = .{
            .left = left,
            .operator = try self.dupe(tok.value),
            .right = right,
            .loc = left.loc(),
        } });
    }
    return left;
}

fn parseBinary(self: *Parser, min_prec: i32) ParseError!*Node {
    var left = try parseUnary(self);
    while (true) {
        const tok = self.peek(0) orelse break;
        if (tok.type != .bin_op) break;
        const prec = precedence.PRECEDENCE.of(tok.value);
        if (prec < 0 or prec < min_prec) break;
        _ = self.advance();
        const right = try parseBinary(self, prec + 1);
        left = try self.create(.{ .binary = .{
            .left = left,
            .operator = try self.dupe(tok.value),
            .right = right,
            .loc = left.loc(),
        } });
    }
    return left;
}

fn parseUnary(self: *Parser) ParseError!*Node {
    const tok = self.peek(0) orelse return parsePostfix(self);
    if (tok.type == .unary_op) {
        _ = self.advance();
        const arg = try parseUnary(self);
        return self.create(.{ .unary = .{
            .operator = try self.dupe(tok.value),
            .arg = arg,
            .loc = arg.loc(),
        } });
    }
    if (tok.type == .bin_op and (std.mem.eql(u8, tok.value, "+") or std.mem.eql(u8, tok.value, "-") or
        std.mem.eql(u8, tok.value, "~") or std.mem.eql(u8, tok.value, "&")))
    {
        _ = self.advance();
        const arg = try parseUnary(self);
        return self.create(.{ .unary = .{
            .operator = try self.dupe(tok.value),
            .arg = arg,
            .loc = arg.loc(),
        } });
    }
    return parsePostfix(self);
}

fn parsePostfix(self: *Parser) ParseError!*Node {
    var e = try parsePrimary(self);
    while (true) {
        const tok = self.peek(0) orelse break;
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "(")) {
            e = try finishCall(self, e);
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, ".")) {
            _ = self.advance();
            const prop = try self.consume(.identifier, "Expected property name", null);
            const prop_node = try self.create(.{ .primary = .{
                .kind = .identifier,
                .name = try self.dupe(prop.value),
                .loc = self.locOf(prop),
            } });
            e = try self.create(.{ .member = .{
                .object = e,
                .property = prop_node,
                .loc = e.loc(),
            } });
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "[")) {
            _ = self.advance();
            // Bounds must not consume `..` (range is slice syntax here, not a binary expr).
            const index_expr = try parseBinary(self, 14);
            var end_expr: ?*Node = null;
            if (self.check(.bin_op) and self.peek(0) != null and std.mem.eql(u8, self.peek(0).?.value, "..")) {
                _ = self.advance(); // '..'
                end_expr = try parseBinary(self, 14);
            }
            _ = try self.consume(.delimiter, "Expected ']'", "]");
            e = try self.create(.{ .index = .{
                .object = e,
                .index = index_expr,
                .end = end_expr,
                .loc = e.loc(),
            } });
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "{")) {
            if (e.* == .primary or e.* == .member) {
                e = try finishStructInit(self, e, tok);
                continue;
            }
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "?")) {
            _ = self.advance();
            e = try self.create(.{ .try_expr = .{ .expression = e, .loc = e.loc() } });
            continue;
        }
        break;
    }
    return e;
}

fn finishStructInit(self: *Parser, type_expr: *Node, tok: ctx.Token) ParseError!*Node {
    _ = self.advance(); // '{'
    var fields: std.ArrayList(ast.StructFieldInit) = .empty;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const field_name = try self.consume(.identifier, "Expected field name in struct initialization", null);
        _ = try self.consume(.delimiter, "Expected ':' after field name", ":");
        const field_value = try parseExpression(self);
        try fields.append(self.arena, .{
            .name = try self.dupe(field_name.value),
            .value = field_value,
        });
        if (self.checkDelim(",")) {
            _ = self.advance();
        } else break;
    }
    _ = try self.consume(.delimiter, "Expected '}' after struct initialization", "}");
    return self.create(.{ .struct_init = .{
        .type_expr = type_expr,
        .fields = try fields.toOwnedSlice(self.arena),
        .loc = self.locOf(tok),
    } });
}

fn finishCall(self: *Parser, callee: *Node) ParseError!*Node {
    _ = try self.consume(.delimiter, "Expected '('", "(");
    var args: std.ArrayList(*Node) = .empty;
    if (!self.checkDelim(")")) {
        while (true) {
            try args.append(self.arena, try parseExpression(self));
            if (self.checkDelim(",")) {
                _ = self.advance();
            } else break;
        }
    }
    _ = try self.consume(.delimiter, "Expected ')'", ")");
    return self.create(.{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(self.arena),
        .loc = callee.loc(),
    } });
}


pub fn parsePrimary(self: *Parser) ParseError!*Node {
    const token = self.peek(0) orelse return self.failMsg("Unexpected end of expression");
    switch (token.type) {
        .boolean, .string, .number, .hex, .binary, .octal => return parseLiteral(self),
        .keyword => {
            if (std.mem.eql(u8, token.value, "error")) {
                _ = self.advance();
                _ = try self.consume(.delimiter, "Expected '(' after error", "(");
                var args: std.ArrayList(*Node) = .empty;
                if (!self.checkDelim(")")) {
                    while (true) {
                        try args.append(self.arena, try parseExpression(self));
                        if (self.checkDelim(",")) {
                            _ = self.advance();
                        } else break;
                    }
                }
                _ = try self.consume(.delimiter, "Expected ')' after error(...)", ")");
                return self.create(.{ .error_expr = .{
                    .args = try args.toOwnedSlice(self.arena),
                    .loc = self.locOf(token),
                } });
            }
            if (std.mem.eql(u8, token.value, "null")) {
                _ = self.advance();
                return self.create(.{ .literal = .{
                    .literal_type = .@"null",
                    .value = try self.dupe("null"),
                    .loc = self.locOf(token),
                } });
            }
        },
        .compiler_keyword => {
            if (std.mem.eql(u8, token.value, "if")) {
                _ = self.advance();
                return control.parseIfExpression(self);
            }
            if (std.mem.eql(u8, token.value, "switch")) {
                _ = self.advance();
                return control.parseSwitchExpression(self);
            }
            if (std.mem.eql(u8, token.value, "for")) {
                _ = self.advance();
                return control.parseForExpression(self);
            }
            _ = self.advance();
            const name = try std.fmt.allocPrint(self.arena, "@{s}", .{token.value});
            return self.create(.{ .primary = .{
                .kind = .identifier,
                .name = name,
                .loc = self.locOf(token),
            } });
        },
        .identifier => {
            if (self.peek(1)) |n| {
                if (n.type == .delimiter and std.mem.eql(u8, n.value, ":")) {
                    if (self.peek(2)) |n2| {
                        if (n2.type == .delimiter and std.mem.eql(u8, n2.value, "{")) {
                            const label = token.value;
                            _ = self.advance();
                            _ = self.advance();
                            return control.parseLabeledBlock(self, label);
                        }
                    }
                }
            }
            _ = self.advance();
            return self.create(.{ .primary = .{
                .kind = .identifier,
                .name = try self.dupe(token.value),
                .loc = self.locOf(token),
            } });
        },
        .v_register => return self.rejectRegisterSigil(token, self.peek(1)),
        .delimiter => {
            if (std.mem.eql(u8, token.value, "(")) {
                _ = self.advance();
                const inner = try parseExpression(self);
                _ = try self.consume(.delimiter, "Expected ')'", ")");
                return inner;
            }
            if (std.mem.eql(u8, token.value, "[")) return parseBracketPrimary(self, token);
            if (std.mem.eql(u8, token.value, "{")) return control.parseBlock(self);
            if (std.mem.eql(u8, token.value, "?") and looksLikeTypeContinuation(self.peek(1))) {
                return types.parseType(self);
            }
        },
        .bin_op => {
            // `*T` as a type expression (e.g. `@sizeOf(*Point)`).
            if (std.mem.eql(u8, token.value, "*") and looksLikeTypeContinuation(self.peek(1))) {
                return types.parseType(self);
            }
        },
        else => {},
    }
    return self.failTok(token, "Unexpected token in expression: {s} at line {d}", .{ token.value, token.line });
}

/// `[` … `]` in expression position: array type (`[]T`, `[N]T`) or array literal (`[1, 2]`).
fn parseBracketPrimary(self: *Parser, token: ctx.Token) ParseError!*Node {
    const t1 = self.peek(1) orelse return parseArrayLiteral(self, token);

    // `[]T` vs `[]`
    if (t1.type == .delimiter and std.mem.eql(u8, t1.value, "]")) {
        if (looksLikeTypeContinuation(self.peek(2))) return types.parseType(self);
        return parseArrayLiteral(self, token);
    }

    // `[N]T` vs `[N]` / `[N, …]`
    if (isArrayLengthToken(t1)) {
        const t2 = self.peek(2) orelse return parseArrayLiteral(self, token);
        if (t2.type == .delimiter and std.mem.eql(u8, t2.value, "]")) {
            if (looksLikeTypeContinuation(self.peek(3))) return types.parseType(self);
        }
    }

    return parseArrayLiteral(self, token);
}

fn isArrayLengthToken(tok: ctx.Token) bool {
    return tok.type == .number or tok.type == .hex or tok.type == .binary or tok.type == .octal;
}

fn looksLikeTypeContinuation(tok: ?ctx.Token) bool {
    const t = tok orelse return false;
    if (t.type == .delimiter and (std.mem.eql(u8, t.value, "[") or std.mem.eql(u8, t.value, "?"))) return true;
    if (t.type == .bin_op and std.mem.eql(u8, t.value, "*")) return true;
    if (t.type == .identifier) return true;
    return t.type == .keyword and (std.mem.eql(u8, t.value, "error") or std.mem.eql(u8, t.value, "null"));
}

fn parseArrayLiteral(self: *Parser, token: ctx.Token) ParseError!*Node {
    _ = self.advance();
    var elements: std.ArrayList(*Node) = .empty;
    if (!self.checkDelim("]")) {
        while (true) {
            try elements.append(self.arena, try parseExpression(self));
            if (self.checkDelim(",")) {
                _ = self.advance();
            } else break;
        }
    }
    _ = try self.consume(.delimiter, "Expected ']'", "]");
    return self.create(.{ .array_literal = .{
        .elements = try elements.toOwnedSlice(self.arena),
        .loc = self.locOf(token),
    } });
}

fn parseLiteral(self: *Parser) ParseError!*Node {
    const token = self.advance() orelse return error.ParseFailed;
    const kind: ast.LiteralKind = switch (token.type) {
        .boolean => .boolean,
        .string => .string,
        .hex => .hex,
        .binary => .binary,
        .octal => .octal,
        .number => .number,
        else => return self.failTok(token, "Invalid literal \"{s}\"", .{token.value}),
    };
    return self.create(.{ .literal = .{
        .literal_type = kind,
        .value = try self.dupe(token.value),
        .loc = self.locOf(token),
    } });
}
