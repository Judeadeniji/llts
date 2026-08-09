const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const decl = @import("decl.zig");
const types = @import("types.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseCompilerStruct(self: *Parser) ParseError!*Node {
    const struct_token = self.previous() orelse return error.ParseFailed;
    const name = try self.consume(.identifier, "Expected struct name", null);
    _ = try self.consume(.delimiter, "Expected '{' before struct body", "{");

    var fields: std.ArrayList(ast.StructField) = .empty;
    var methods: std.ArrayList(*Node) = .empty;

    while (!self.isAtEnd() and !self.checkDelim("}")) {
        if (self.check(.compiler_keyword)) {
            if (self.peek(0)) |t| {
                if (std.mem.eql(u8, t.value, "func")) {
                    _ = self.advance();
                    const func = try decl.parseCompilerFunc(self);
                    if (func.* == .function_decl) {
                        const mangled = try std.fmt.allocPrint(
                            self.arena,
                            "{s}::{s}",
                            .{ name.value, func.function_decl.name },
                        );
                        func.function_decl.name = mangled;
                    }
                    try methods.append(self.arena, func);
                    continue;
                }
            }
        }

        const field_name = try self.consume(.identifier, "Expected field name in struct declaration", null);
        _ = try self.consume(.delimiter, "Expected ':' after field name", ":");
        const field_type = try types.parseType(self);
        _ = try self.consume(.delimiter, "Expected ';' after field declaration", ";");
        try fields.append(self.arena, .{
            .name = try self.dupe(field_name.value),
            .type_annotation = field_type,
        });
    }

    _ = try self.consume(.delimiter, "Expected '}' after struct body", "}");

    return self.create(.{ .struct_decl = .{
        .name = try self.dupe(name.value),
        .fields = try fields.toOwnedSlice(self.arena),
        .methods = try methods.toOwnedSlice(self.arena),
        .loc = self.locOf(struct_token),
    } });
}
