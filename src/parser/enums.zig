const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

/// `@enum Name { A, B = 2, C = "text" }`
pub fn parseCompilerEnum(self: *Parser) ParseError!*Node {
    const enum_token = self.previous() orelse return error.ParseFailed;
    const name = try self.consume(.identifier, "Expected enum name", null);
    _ = try self.consume(.delimiter, "Expected '{' before enum body", "{");

    var variants: std.ArrayList(ast.EnumVariant) = .empty;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const variant = try self.consume(.identifier, "Expected enum variant name", null);
        var value: ?*Node = null;
        if (self.check(.assign_op)) {
            const eq = self.peek(0) orelse return error.ParseFailed;
            if (!std.mem.eql(u8, eq.value, "="))
                return self.failMsg("Expected '=' or ',' after enum variant name");
            _ = self.advance(); // consume '='
            const val_token = self.peek(0) orelse return error.ParseFailed;
            // The value must be an integer or string literal (a numeric
            // variant's backing value, or a string-tagged variant).
            const lit = switch (val_token.type) {
                .number, .hex, .octal, .binary => ast.Literal{ .literal_type = .number, .value = try self.dupe(val_token.value), .loc = self.locOf(val_token) },
                .string => ast.Literal{ .literal_type = .string, .value = try self.dupe(val_token.value), .loc = self.locOf(val_token) },
                else => return self.failMsg("Enum variant value must be an integer or string literal"),
            };
            _ = self.advance(); // consume the literal
            value = try self.create(.{ .literal = lit });
        }
        try variants.append(self.arena, .{
            .name = try self.dupe(variant.value),
            .value = value,
        });
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
