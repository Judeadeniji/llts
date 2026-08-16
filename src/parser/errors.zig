const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseCompilerError(self: *Parser) ParseError!*Node {
    const err_token = self.previous() orelse return error.ParseFailed;
    const name = try self.consume(.identifier, "Expected error set name", null);
    _ = try self.consume(.delimiter, "Expected '{' before error set body", "{");

    var variants: std.ArrayList([]const u8) = .empty;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const variant = try self.consume(.identifier, "Expected error set member name", null);
        try variants.append(self.arena, try self.dupe(variant.value));
        if (self.checkDelim(",")) {
            _ = self.advance();
        } else if (!self.checkDelim("}")) {
            return self.failMsg("Expected ',' or '}' after error set member");
        }
    }

    _ = try self.consume(.delimiter, "Expected '}' after error set body", "}");

    return self.create(.{ .error_decl = .{
        .name = try self.dupe(name.value),
        .variants = try variants.toOwnedSlice(self.arena),
        .loc = self.locOf(err_token),
    } });
}
