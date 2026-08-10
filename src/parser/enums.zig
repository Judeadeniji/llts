const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseCompilerEnum(self: *Parser) ParseError!*Node {
    const enum_token = self.previous() orelse return error.ParseFailed;
    const name = try self.consume(.identifier, "Expected enum name", null);
    _ = try self.consume(.delimiter, "Expected '{' before enum body", "{");

    var variants: std.ArrayList([]const u8) = .empty;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const variant = try self.consume(.identifier, "Expected enum variant name", null);
        try variants.append(self.arena, try self.dupe(variant.value));
        if (self.checkDelim(",")) {
            _ = self.advance();
        } else if (!self.checkDelim("}")) {
            return self.failMsg("Expected ',' or '}' after enum variant");
        }
    }

    _ = try self.consume(.delimiter, "Expected '}' after enum body", "}");

    return self.create(.{ .enum_decl = .{
        .name = try self.dupe(name.value),
        .variants = try variants.toOwnedSlice(self.arena),
        .loc = self.locOf(enum_token),
    } });
}
