const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

/// Parse a type: `[]T`, `[N]T`, nested `[2][3]int`, `Name`, or `T | U`.
pub fn parseType(self: *Parser) ParseError!*Node {
    var left: *Node = undefined;
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
        left = try self.create(.{ .array_type = .{
            .elem = elem,
            .length_text = length_text,
            .loc = self.locOf(start),
        } });
    } else {
        left = try parseTypeAtom(self);
    }

    while (self.checkDelim("|")) {
        _ = self.advance();
        const right = try parseTypeAtom(self);
        const peek = self.peek(0) orelse self.previous().?;
        left = try self.create(.{ .union_type = .{
            .left = left,
            .right = right,
            .loc = self.locOf(peek),
        } });
    }
    return left;
}

fn parseTypeAtom(self: *Parser) ParseError!*Node {
    const peek = self.peek(0) orelse return self.failMsg("Expected type name");
    if (peek.type == .keyword and std.mem.eql(u8, peek.value, "error")) {
        _ = self.advance();
        return self.create(.{ .primary = .{
            .kind = .identifier,
            .name = try self.dupe("error"),
            .loc = self.locOf(peek),
        } });
    }
    const type_name = try self.consume(.identifier, "Expected type name", null);
    return self.create(.{ .primary = .{
        .kind = .identifier,
        .name = try self.dupe(type_name.value),
        .loc = self.locOf(type_name),
    } });
}
