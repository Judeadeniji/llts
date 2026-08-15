const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

/// Parse a type: `?T`, `*T`, `[]T`, `[N]T`, nested `[2][3]int`, `Name`, or `T | U`.
/// `?T` is sugar for `T | null`. `?` and `*` bind tighter than `|`.
/// `?*T` parses as optional-of-pointer.
pub fn parseType(self: *Parser) ParseError!*Node {
    var left = try parseTypeOperand(self);
    while (self.checkDelim("|")) {
        _ = self.advance();
        const right = try parseTypeOperand(self);
        const peek = self.peek(0) orelse self.previous().?;
        left = try self.create(.{ .union_type = .{
            .left = left,
            .right = right,
            .loc = self.locOf(peek),
        } });
    }
    return left;
}

fn parseTypeOperand(self: *Parser) ParseError!*Node {
    if (self.checkDelim("?")) {
        const start = self.peek(0).?;
        _ = self.advance();
        const inner = try parseTypeOperand(self);
        const null_node = try self.create(.{ .primary = .{
            .kind = .identifier,
            .name = try self.dupe("null"),
            .loc = self.locOf(start),
        } });
        return self.create(.{ .union_type = .{
            .left = inner,
            .right = null_node,
            .loc = self.locOf(start),
        } });
    }

    if (self.checkDelim("*")) {
        const start = self.peek(0).?;
        _ = self.advance();
        const elem = try parseTypeOperand(self);
        return self.create(.{ .pointer_type = .{
            .elem = elem,
            .loc = self.locOf(start),
        } });
    }

    if (self.checkDelim("[")) {
        const start = self.peek(0).?;
        _ = self.advance();
        var length_text: ?[]const u8 = null;
        if (self.check(.number) or self.check(.hex) or self.check(.octal) or self.check(.binary)) {
            const num_tok = self.advance().?;
            length_text = try self.dupe(num_tok.value);
        }
        _ = try self.consume(.delimiter, "Expected ']' in array type", "]");
        const elem = try parseType(self);
        return self.create(.{ .array_type = .{
            .elem = elem,
            .length_text = length_text,
            .loc = self.locOf(start),
        } });
    }

    return parseTypeAtom(self);
}

fn parseTypeAtom(self: *Parser) ParseError!*Node {
    const peek = self.peek(0) orelse return self.failMsg("Expected type name");
    if (peek.type == .keyword and (std.mem.eql(u8, peek.value, "error") or std.mem.eql(u8, peek.value, "null"))) {
        _ = self.advance();
        return self.create(.{ .primary = .{
            .kind = .identifier,
            .name = try self.dupe(peek.value),
            .loc = self.locOf(peek),
        } });
    }
    const type_name = try self.consume(.identifier, "Expected type name", null);
    var node = try self.create(.{ .primary = .{
        .kind = .identifier,
        .name = try self.dupe(type_name.value),
        .loc = self.locOf(type_name),
    } });
    // `mem.Arena`, `lib.Point`
    while (self.checkDelim(".")) {
        _ = self.advance();
        const prop = try self.consume(.identifier, "Expected type name after '.'", null);
        const prop_node = try self.create(.{ .primary = .{
            .kind = .identifier,
            .name = try self.dupe(prop.value),
            .loc = self.locOf(prop),
        } });
        node = try self.create(.{ .member = .{
            .object = node,
            .property = prop_node,
            .loc = node.loc(),
        } });
    }
    return node;
}
