const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const stmt_mod = @import("stmt.zig");
const expr = @import("expr.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseBlock(self: *Parser) ParseError!*Node {
    _ = try self.consume(.delimiter, "Expected '{'", "{");
    var statements: std.ArrayList(*Node) = .empty;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        try statements.append(self.arena, try stmt_mod.parseStatement(self));
    }
    _ = try self.consume(.delimiter, "Expected '}'", "}");
    const peek = self.peek(0);
    const loc: ast.Location = if (peek) |t| self.locOf(t) else .{};
    return self.create(.{ .block = .{
        .statements = try statements.toOwnedSlice(self.arena),
        .loc = loc,
    } });
}

pub fn parseLabeledBlock(self: *Parser, label: []const u8) ParseError!*Node {
    const block = try parseBlock(self);
    block.block.label = try self.dupe(label);
    return block;
}

pub fn parseSwitchExpression(self: *Parser) ParseError!*Node {
    const switch_token = self.previous() orelse return error.ParseFailed;
    _ = try self.consume(.delimiter, "Expects \"(\"", "(");
    const cond = try expr.parseExpression(self);
    _ = try self.consume(.delimiter, "Expects \")\"", ")");
    _ = try self.consume(.delimiter, "Expected '{' before switch body", "{");

    var prongs: std.ArrayList(ast.SwitchProng) = .empty;
    var saw_else = false;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const prong_loc = if (self.peek(0)) |t| self.locOf(t) else ast.Location{};
        var is_else = false;
        var patterns: std.ArrayList(*Node) = .empty;

        if (self.check(.compiler_keyword)) {
            if (self.peek(0)) |t| {
                if (std.mem.eql(u8, t.value, "else")) {
                    _ = self.advance();
                    is_else = true;
                    saw_else = true;
                }
            }
        }

        if (!is_else) {
            if (saw_else) {
                return self.failMsg("Additional switch prongs are not allowed after '@else'");
            }
            while (true) {
                try patterns.append(self.arena, try expr.parseExpression(self));
                if (self.checkDelim(",")) {
                    _ = self.advance();
                    // Trailing comma before `=>` is not allowed; require another pattern.
                    if (self.check(.bin_op) and self.peek(0) != null and std.mem.eql(u8, self.peek(0).?.value, "=>")) {
                        return self.failMsg("Expected pattern after ',' in switch prong");
                    }
                    continue;
                }
                break;
            }
        }

        // `=>` is scanned as bin_op
        const arrow = self.peek(0) orelse return self.failMsg("Expected '=>' in switch prong");
        if (arrow.type != .bin_op or !std.mem.eql(u8, arrow.value, "=>")) {
            return self.failTok(arrow, "Expected '=>' in switch prong", .{});
        }
        _ = self.advance();

        const body = try parseBlock(self);
        if (self.checkDelim(",")) _ = self.advance();

        try prongs.append(self.arena, .{
            .patterns = try patterns.toOwnedSlice(self.arena),
            .is_else = is_else,
            .body = body,
            .loc = prong_loc,
        });
    }

    _ = try self.consume(.delimiter, "Expected '}' after switch body", "}");
    return self.create(.{ .switch_expr = .{
        .condition = cond,
        .prongs = try prongs.toOwnedSlice(self.arena),
        .loc = self.locOf(switch_token),
    } });
}

pub fn parseIfExpression(self: *Parser) ParseError!*Node {
    const if_token = self.previous() orelse return error.ParseFailed;
    _ = try self.consume(.delimiter, "Expects \"(\"", "(");
    const cond = try expr.parseExpression(self);
    _ = try self.consume(.delimiter, "Expects \")\"", ")");

    var pipe_value: ?*Node = null;
    if (self.checkDelim("|")) {
        _ = self.advance();
        pipe_value = try expr.parsePrimary(self);
        _ = try self.consume(.delimiter, "Expected \"|\" after pipe capture", "|");
    }

    const body = try parseBlock(self);
    var else_body: ?*Node = null;

    if (self.check(.compiler_keyword)) {
        if (self.peek(0)) |t| {
            if (std.mem.eql(u8, t.value, "else")) {
                _ = self.advance();
                if (self.check(.compiler_keyword)) {
                    if (self.peek(0)) |t2| {
                        if (std.mem.eql(u8, t2.value, "if")) {
                            _ = self.advance();
                            else_body = try parseIfExpression(self);
                        } else {
                            else_body = try parseBlock(self);
                        }
                    }
                } else {
                    else_body = try parseBlock(self);
                }
            }
        }
    }

    return self.create(.{ .if_expr = .{
        .condition = cond,
        .pipe_value = pipe_value,
        .body = body,
        .else_body = else_body,
        .loc = self.locOf(if_token),
    } });
}

pub fn parseForExpression(self: *Parser) ParseError!*Node {
    const for_token = self.previous() orelse return error.ParseFailed;
    _ = try self.consume(.delimiter, "Expects \"(\"", "(");
    const expr1 = try expr.parseExpression(self);

    if (self.checkDelim(";")) {
        return self.failTok(for_token, "C-style for loops are not supported. Use '@for (0..N) |i|' for range loops or '@for (condition)' for condition loops.", .{});
    }

    if (self.checkDelim(",")) {
        _ = self.advance();
        _ = try self.consume(.number, "Expected '0' for array index range", "0");
        _ = try self.consume(.bin_op, "Expected '..' for array index range", "..");
    }

    _ = try self.consume(.delimiter, "Expects \")\"", ")");

    var captures: std.ArrayList(ast.Capture) = .empty;
    if (self.checkDelim("|")) {
        _ = self.advance();
        while (true) {
            const name = try self.consume(.identifier, "Expected capture name", null);
            try captures.append(self.arena, .{ .name = try self.dupe(name.value), .by_ref = false });
            if (self.checkDelim(",")) {
                _ = self.advance();
            } else break;
        }
        _ = try self.consume(.delimiter, "Expected '|' to close captures", "|");
    }

    const body = try parseBlock(self);
    const caps = try captures.toOwnedSlice(self.arena);

    return self.create(.{ .for_expr = .{
        .expr = expr1,
        .captures = caps,
        .label = null,
        .body = body,
        .loc = self.locOf(for_token),
    } });
}

pub fn parseReturnStatement(self: *Parser) ParseError!*Node {
    const keyword = try self.consume(.keyword, "Expected \"return\"", "return");
    var return_value: ?*Node = null;
    if (!self.checkDelim(";")) {
        return_value = try expr.parseExpression(self);
    }
    _ = try self.consume(.delimiter, "Expected \";\"", ";");
    return self.create(.{ .return_expr = .{
        .return_value = return_value,
        .loc = self.locOf(keyword),
    } });
}

pub fn parseDeferStatement(self: *Parser, is_errdefer: bool) ParseError!*Node {
    const kw = if (is_errdefer) "errdefer" else "defer";
    const keyword = try self.consume(.keyword, "Expected keyword", kw);
    const body: *Node = if (self.checkDelim("{"))
        try parseBlock(self)
    else blk: {
        const e = try expr.parseExpression(self);
        _ = try self.consume(.delimiter, "Expected \";\" after defer", ";");
        break :blk e;
    };
    return self.create(.{ .defer_stmt = .{ .body = body, .is_errdefer = is_errdefer, .loc = self.locOf(keyword) } });
}

pub fn parseBreakStatement(self: *Parser) ParseError!*Node {
    const keyword = try self.consume(.keyword, "Expected \"break\"", "break");
    var label: ?[]const u8 = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        const lab = try self.consume(.identifier, "Expected label after ':' in break statement", null);
        label = try self.dupe(lab.value);
    }
    var value: ?*Node = null;
    if (!self.checkDelim(";")) {
        value = try expr.parseExpression(self);
    }
    _ = try self.consume(.delimiter, "Expected \";\"", ";");
    return self.create(.{ .break_expr = .{
        .label = label,
        .value = value,
        .loc = self.locOf(keyword),
    } });
}

pub fn parseContinueStatement(self: *Parser) ParseError!*Node {
    const keyword = try self.consume(.keyword, "Expected \"continue\"", "continue");
    var label: ?[]const u8 = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        const lab = try self.consume(.identifier, "Expected label after ':' in continue statement", null);
        label = try self.dupe(lab.value);
    }
    _ = try self.consume(.delimiter, "Expected \";\"", ";");
    return self.create(.{ .continue_expr = .{ .label = label, .loc = self.locOf(keyword) } });
}
