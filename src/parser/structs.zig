const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const decl = @import("decl.zig");
const types = @import("types.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseCompilerStruct(self: *Parser) ParseError!*Node {
    return parseCompilerStructWithExtern(self, false, null);
}

/// Parses `@struct Name { ... }` or `@extern "<abi>" @struct Name { ... }`.
/// When `is_extern` is true, the struct represents an extern ABI aggregate layout.
pub fn parseCompilerStructWithExtern(self: *Parser, is_extern: bool, abi: ?[]const u8) ParseError!*Node {
    const struct_token = self.previous() orelse return error.ParseFailed;
    const name = try self.consume(.identifier, "Expected struct name", null);
    // `@struct Name(T: type)` — generic struct template.
    var params: []ast.Param = &.{};
    if (self.checkDelim("(")) {
        _ = self.advance();
        params = (try decl.parseParamsList(self)).elements;
        // Extern ABI structs have fixed memory layouts and cannot be generic templates.
        if (is_extern and params.len > 0) {
            return self.failTokRaw(struct_token, "extern struct declarations cannot be generic");
        }
    }
    _ = try self.consume(.delimiter, "Expected '{' before struct body", "{");

    var fields: std.ArrayList(ast.StructField) = .empty;
    var methods: std.ArrayList(*Node) = .empty;

    while (!self.isAtEnd() and !self.checkDelim("}")) {
        if (self.check(.compiler_keyword)) {
            if (self.peek(0)) |t| {
                if (std.mem.eql(u8, t.value, "func")) {
                    _ = self.advance();
                    const func = try decl.parseCompilerFunc(self);
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
        .params = params,
        .is_extern = is_extern,
        .abi = if (abi) |a| try self.dupe(a) else null,
        .loc = self.locOf(struct_token),
    } });
}
