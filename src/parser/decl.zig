const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const stmt_mod = @import("stmt.zig");
const types = @import("types.zig");
const control = @import("control.zig");
const structs = @import("structs.zig");
const enums = @import("enums.zig");
const expr = @import("expr.zig");
const errors_mod = @import("errors.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;
const Location = ast.Location;

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
    const eq_msg = std.fmt.bufPrint(&msg_buf, "Expected '=' after '{s}'", .{register.value}) catch "Expected '=' after register";
    _ = try self.consume(.assign_op, eq_msg, "=");
    // `$p: Point = { x: 1, y: 2 }` — annotated bare object init (not a block).
    const value = if (type_node != null and expr.looksLikeFieldInitObject(self))
        try expr.parseStructInitWithType(self, type_node.?)
    else
        try expr.parseExpression(self);

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
    if (std.mem.eql(u8, keyword.value, "error")) return errors_mod.parseCompilerError(self);
    if (std.mem.eql(u8, keyword.value, "type")) return parseTypeDecl(self, true);
    if (std.mem.eql(u8, keyword.value, "alias")) return parseTypeDecl(self, false);
    if (std.mem.eql(u8, keyword.value, "extern")) return parseCompilerExtern(self);

    // Any other `@name(...)` parses as a statement-level expression call
    self.current -= 1;
    return stmt_mod.parseExpressionStatement(self);
}

fn parseCompilerExtern(self: *Parser) ParseError!*Node {
    const extern_kw = self.previous() orelse return error.ParseFailed;

    if (self.block_depth != 0) {
        return self.failTokRaw(extern_kw, "@extern declarations are only allowed at file scope");
    }

    // The legacy form had no ABI string: `@extern Name;`.
    if (self.check(.identifier)) {
        return self.failTokRaw(extern_kw, "legacy '@extern Name;' declarations are not supported; write '@extern \"c\" @func Name(params): return_type;'");
    }

    const abi = try self.consume(
        .string,
        "Expected ABI string after @extern, e.g. @extern \"c\" @func puts(s: c_str): i32;",
        null,
    );

    if (self.checkKeyword("func")) {
        return parseExternFunc(self, abi.value);
    }
    if (self.check(.identifier)) {
        return parseExternData(self, abi.value);
    }

    return self.failTokRaw(extern_kw, "Expected '@func' or a data declaration after the @extern ABI string");
}

const ExternParamsResult = struct {
    params: []ast.Param,
    is_c_variadic: bool,
};

fn parseExternFunc(
    self: *Parser,
    abi: []const u8,
) ParseError!*Node {
    _ = self.advance(); // `@func`
    const name = try self.consume(.identifier, "Expected function name after @func", null);
    _ = try self.consume(.delimiter, "Expected '(' after extern function name", "(");

    const parsed = try parseExternParams(self);

    var return_type: ?*Node = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        return_type = try types.parseType(self);
    }

    if (self.checkDelim("{")) {
        return self.failTokRaw(self.peek(0).?, "extern function declarations cannot have a body");
    }
    _ = try self.consume(.delimiter, "Expected ';' after extern function declaration", ";");

    const source_name = try self.dupe(name.value);
    return self.create(.{ .extern_decl = .{
        .name = source_name,
        .symbol = source_name,
        .abi = try self.dupe(abi),
        .kind = .func,
        .params = parsed.params,
        .return_type = return_type,
        .is_c_variadic = parsed.is_c_variadic,
        .loc = self.locOf(name),
    } });
}

fn parseExternParams(self: *Parser) ParseError!ExternParamsResult {
    var params: std.ArrayList(ast.Param) = .empty;
    var is_c_variadic = false;

    if (self.checkDelim(")")) {
        _ = self.advance();
        return .{ .params = try params.toOwnedSlice(self.arena), .is_c_variadic = false };
    }

    while (true) {
        if (self.checkDelim("...")) {
            const dots = self.advance() orelse return error.ParseFailed;
            if (params.items.len == 0) {
                return self.failTokRaw(dots, "variadic extern declaration requires at least one fixed parameter before '...'");
            }
            is_c_variadic = true;
            if (!self.checkDelim(")")) {
                const next = self.peek(0) orelse dots;
                return self.failTokRaw(next, "no parameter may follow '...' in an extern declaration");
            }
            _ = self.advance(); // `)`
            break;
        }

        const name = try self.consume(.identifier, "Expected parameter name in extern declaration", null);
        _ = try self.consume(.delimiter, "Expected ':' before extern parameter type", ":");
        const type_node = try types.parseType(self);

        try params.append(self.arena, .{
            .name = try self.dupe(name.value),
            .type_annotation = type_node,
            .is_rest = false,
            .loc = self.locOf(name),
        });

        if (self.checkDelim(",")) {
            _ = self.advance();
            continue;
        }
        _ = try self.consume(.delimiter, "Expected ')' after extern parameters", ")");
        break;
    }

    return .{
        .params = try params.toOwnedSlice(self.arena),
        .is_c_variadic = is_c_variadic,
    };
}

fn parseExternData(self: *Parser, abi: []const u8) ParseError!*Node {
    const name = try self.consume(.identifier, "Expected extern symbol name", null);
    if (!self.checkDelim(":")) {
        return self.failTokRaw(
            self.peek(0) orelse name,
            "expected ':' after extern data symbol name; extern data symbols are not supported yet",
        );
    }
    _ = self.advance();
    const data_type = try types.parseType(self);
    _ = try self.consume(.delimiter, "Expected ';' after extern data declaration", ";");

    const source_name = try self.dupe(name.value);
    return self.create(.{ .extern_decl = .{
        .name = source_name,
        .symbol = source_name,
        .abi = try self.dupe(abi),
        .kind = .data,
        .params = &.{},
        .data_type = data_type,
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
    var fn_name: []const u8 = "";
    var name_loc = if (self.previous()) |tok| self.locOf(tok) else Location{ .path = self.path };
    if (self.checkDelim("(")) {
        _ = self.advance();
    } else {
        const name = self.advance() orelse return error.ParseFailed;
        if (name.type != .identifier) {
            return self.failTok(name, "Invalid function name '{s}'", .{name.value});
        }
        fn_name = try self.dupe(name.value);
        name_loc = self.locOf(name);
        _ = try self.consume(.delimiter, "Expected '(' after function name", "(");
    }

    const parsed = try parseParamsList(self);
    const params_node = try self.create(.{ .params = .{
        .params = parsed.elements,
        .is_variadic = parsed.is_variadic,
        .loc = name_loc,
    } });

    var return_type: ?*Node = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        return_type = try types.parseType(self);
    }

    const saved_in_type_fn = self.in_type_fn;
    self.in_type_fn = if (return_type) |rt| rt.* == .primary and std.mem.eql(u8, rt.primary.name, "type") else false;
    defer self.in_type_fn = saved_in_type_fn;
    const body = try control.parseBlock(self);
    return self.create(.{ .function_decl = .{
        .name = fn_name,
        .params = params_node,
        .body = body,
        .return_type = return_type,
        .loc = name_loc,
    } });
}

pub const ParamsResult = struct { elements: []ast.Param, is_variadic: bool };

/// `name: T, …)` — params up to and including the closing `)`.
pub fn parseParamsList(self: *Parser) ParseError!ParamsResult {
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
