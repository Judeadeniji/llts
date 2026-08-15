const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const stmt_mod = @import("stmt.zig");
const types = @import("types.zig");
const control = @import("control.zig");
const structs = @import("structs.zig");
const enums = @import("enums.zig");

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
    const expr = @import("expr.zig");
    const value = try expr.parseExpression(self);

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

    if (std.mem.eql(u8, keyword.value, "const")) return parseDeclaration(self, true);
    if (std.mem.eql(u8, keyword.value, "func")) return parseCompilerFunc(self);
    if (std.mem.eql(u8, keyword.value, "for")) return control.parseForExpression(self);
    if (std.mem.eql(u8, keyword.value, "if")) return control.parseIfExpression(self);
    if (std.mem.eql(u8, keyword.value, "switch")) return control.parseSwitchExpression(self);
    if (std.mem.eql(u8, keyword.value, "struct")) return structs.parseCompilerStruct(self);
    if (std.mem.eql(u8, keyword.value, "enum")) return enums.parseCompilerEnum(self);
    if (std.mem.eql(u8, keyword.value, "type")) return parseTypeDecl(self, true);
    if (std.mem.eql(u8, keyword.value, "alias")) return parseTypeDecl(self, false);
    if (std.mem.eql(u8, keyword.value, "extern")) return parseCompilerExtern(self);

    // Any other `@name(...)` parses as a statement-level expression call
    self.current -= 1;
    return stmt_mod.parseExpressionStatement(self);
}

fn parseCompilerExtern(self: *Parser) ParseError!*Node {
    const name = try self.consume(.identifier, "Expected identifier after @extern", null);
    _ = try self.consume(.delimiter, "Expected ';' after @extern declaration", ";");
    return self.create(.{ .extern_decl = .{
        .name = try self.dupe(name.value),
        .loc = self.locOf(name),
    } });
}

fn parseTypeDecl(self: *Parser, distinct: bool) ParseError!*Node {
    const kw = self.previous() orelse return error.ParseFailed;
    const name = try self.consume(.identifier, if (distinct) "Expected name after @type" else "Expected name after @alias", null);
    _ = try self.consume(.assign_op, "Expected '=' after type name", "=");
    const type_expr = try types.parseType(self);
    if (self.checkDelim(";")) _ = self.advance();
    return self.create(.{ .type_decl = .{
        .name = try self.dupe(name.value),
        .type_expr = type_expr,
        .distinct = distinct,
        .loc = self.locOf(kw),
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

const ParamsResult = struct { elements: []ast.Param, is_variadic: bool };

fn parseParamsList(self: *Parser) ParseError!ParamsResult {
    if (self.checkDelim(")")) {
        _ = self.advance();
        return .{ .elements = &.{}, .is_variadic = false };
    }

    var params: std.ArrayList(ast.Param) = .empty;
    var is_variadic = false;

    while (true) {
        const is_rest = self.checkDelim("...");
        if (is_rest) {
            _ = self.advance();
            is_variadic = true;
        }

        const name = try self.consume(.identifier, "Expected parameter name", null);
        var type_node: ?*Node = null;
        if (self.checkDelim(":")) {
            _ = self.advance();
            type_node = try types.parseType(self);
        }

        try params.append(self.arena, .{
            .name = try self.dupe(name.value),
            .type_annotation = type_node,
            .is_rest = is_rest,
            .loc = self.locOf(name),
        });

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

