const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const stmt_mod = @import("stmt.zig");
const types = @import("types.zig");
const control = @import("control.zig");
const structs = @import("structs.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseDeclaration(self: *Parser, is_const: bool) ParseError!*Node {
    const register = try self.consume(
        .v_register,
        "Expected $RegisterName",
        null,
    );

    var type_node: ?*Node = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        type_node = try types.parseType(self);
    }

    var msg_buf: [128]u8 = undefined;
    const eq_msg = std.fmt.bufPrint(&msg_buf, "Expected \"=\" after \"{s}\"", .{register.value}) catch "Expected \"=\" after register";
    _ = try self.consume(.assign_op, eq_msg, "=");
    const value = try stmt_mod.parseStatement(self);

    if (self.checkDelim(";")) _ = self.advance();

    return self.create(.{ .declaration = .{
        .name = try self.dupe(register.value),
        .value = value,
        .is_const = is_const,
        .type_annotation = type_node,
        .loc = self.locOf(register),
    } });
}

pub fn parseCompilerKeyword(self: *Parser) ParseError!*Node {
    const keyword = self.advance() orelse return error.ParseFailed;
    if (keyword.type != .compiler_keyword) {
        return self.failTok(keyword, "Expected compiler keyword", .{});
    }

    if (std.mem.eql(u8, keyword.value, "import")) return parseCompilerImport(self);
    if (std.mem.eql(u8, keyword.value, "const")) return parseDeclaration(self, true);
    if (std.mem.eql(u8, keyword.value, "typeOf") or std.mem.eql(u8, keyword.value, "isError")) {
        self.current -= 1;
        return stmt_mod.parseExpressionStatement(self);
    }
    if (std.mem.eql(u8, keyword.value, "func")) return parseCompilerFunc(self);
    if (std.mem.eql(u8, keyword.value, "for")) return control.parseForExpression(self);
    if (std.mem.eql(u8, keyword.value, "if")) return control.parseIfExpression(self);
    if (std.mem.eql(u8, keyword.value, "struct")) return structs.parseCompilerStruct(self);
    if (std.mem.eql(u8, keyword.value, "extern")) return parseCompilerExtern(self);

    return self.failTok(keyword, "Unhandled compiler keyword: {s}", .{keyword.value});
}

fn parseCompilerExtern(self: *Parser) ParseError!*Node {
    const name = try self.consume(.identifier, "Expected identifier after @extern", null);
    _ = try self.consume(.delimiter, "Expected ';' after @extern declaration", ";");
    return self.create(.{ .extern_decl = .{
        .name = try self.dupe(name.value),
        .loc = self.locOf(name),
    } });
}

pub fn parseCompilerFunc(self: *Parser) ParseError!*Node {
    const name = self.advance() orelse return error.ParseFailed;
    if (name.type != .identifier) {
        return self.failTok(name, "Expected a valid function name but found \"{s}\" instead.", .{name.value});
    }

    _ = try self.consume(.delimiter, "Expected '(' after function name", "(");
    const parsed = try parseParamsList(self);
    const params_node = try self.create(.{ .params = .{
        .params = parsed.elements,
        .is_variadic = parsed.is_variadic,
        .loc = self.locOf(name),
    } });

    var return_type: ?*Node = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        return_type = try types.parseType(self);
    }

    const body = try control.parseBlock(self);
    return self.create(.{ .function_decl = .{
        .name = try self.dupe(name.value),
        .params = params_node,
        .body = body,
        .return_type = return_type,
        .loc = self.locOf(name),
    } });
}

const ParamsResult = struct { elements: []*Node, is_variadic: bool };

fn parseParamsList(self: *Parser) ParseError!ParamsResult {
    if (self.checkDelim(")")) {
        _ = self.advance();
        return .{ .elements = &.{}, .is_variadic = false };
    }

    var params: std.ArrayList(*Node) = .empty;
    var is_variadic = false;

    while (true) {
        if (self.checkDelim("...")) {
            _ = self.advance();
            is_variadic = true;
        }

        const name = try self.consume(.identifier, "Expected parameter name", null);
        var type_node: ?*Node = null;
        if (self.checkDelim(":")) {
            _ = self.advance();
            type_node = try types.parseType(self);
        }

        const dummy = try self.create(.{ .literal = .{
            .literal_type = .number,
            .value = try self.dupe("0"),
            .loc = self.locOf(name),
        } });
        try params.append(self.arena, try self.create(.{ .declaration = .{
            .name = try self.dupe(name.value),
            .value = dummy,
            .type_annotation = type_node,
            .loc = self.locOf(name),
        } }));

        if (is_variadic and self.checkDelim(",")) {
            return self.failTok(self.peek(0).?, "Rest parameter must be the last parameter", .{});
        }

        if (self.match(.delimiter)) {
            const prev = self.previous() orelse break;
            if (std.mem.eql(u8, prev.value, ",")) continue;
            // ')' consumed by match
            break;
        }
        break;
    }

    return .{
        .elements = try params.toOwnedSlice(self.arena),
        .is_variadic = is_variadic,
    };
}

fn parseCompilerImport(self: *Parser) ParseError!*Node {
    const left_paren = self.peek(0) orelse return error.ParseFailed;
    if (!std.mem.eql(u8, left_paren.value, "(")) {
        return self.failTok(left_paren, "Expected \"(\" after import", .{});
    }
    _ = self.advance();

    const path_tok = self.peek(0) orelse return error.ParseFailed;
    if (path_tok.type != .string) {
        return self.failTok(path_tok, "Unexpected import value \"{s}\". Expected a valid path.", .{path_tok.value});
    }
    const import_path = self.advance() orelse return error.ParseFailed;

    const rp = self.peek(0) orelse return error.ParseFailed;
    if (!std.mem.eql(u8, rp.value, ")")) {
        return self.failTok(rp, "Expected \")\" after import path", .{});
    }
    _ = self.advance();
    _ = try self.consume(.delimiter, "Expected ';' after import statement", ";");

    return self.create(.{ .import = .{
        .import_path = try self.dupe(import_path.value),
        .loc = self.locOf(import_path),
    } });
}
