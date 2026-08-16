const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

/// Parse a type: `?T`, `*T`, `[]T`, `[N]T`, `[T, U, …]`, `{ f: T; … }`, `@func(…): R`, nested `[2][3]int`, `Name`, `T & U`, or `T | U`.
/// `?T` is sugar for `T | null`. `?` and `*` bind tighter than `&` / `|`; `&` binds tighter than `|`.
/// `?*T` parses as optional-of-pointer.
pub fn parseType(self: *Parser) ParseError!*Node {
    var left = try parseIntersection(self);
    while (self.checkDelim("|")) {
        _ = self.advance();
        const right = try parseIntersection(self);
        const peek = self.peek(0) orelse self.previous().?;
        left = try self.create(.{ .union_type = .{
            .left = left,
            .right = right,
            .loc = self.locOf(peek),
        } });
    }
    return left;
}

fn parseIntersection(self: *Parser) ParseError!*Node {
    var left = try parseTypeOperand(self);
    while (self.checkDelim("&")) {
        _ = self.advance();
        const right = try parseTypeOperand(self);
        const peek = self.peek(0) orelse self.previous().?;
        left = try self.create(.{ .intersection_type = .{
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

        // `[]T`
        if (self.checkDelim("]")) {
            _ = self.advance();
            const elem = try parseType(self);
            return self.create(.{ .array_type = .{
                .elem = elem,
                .length_text = null,
                .loc = self.locOf(start),
            } });
        }

        // `[N]T` — length token immediately followed by `]`
        if (self.check(.number) or self.check(.hex) or self.check(.octal) or self.check(.binary)) {
            if (self.peek(1)) |n1| {
                if (n1.type == .delimiter and std.mem.eql(u8, n1.value, "]")) {
                    const num_tok = self.advance().?;
                    _ = self.advance(); // `]`
                    const elem = try parseType(self);
                    return self.create(.{ .array_type = .{
                        .elem = elem,
                        .length_text = try self.dupe(num_tok.value),
                        .loc = self.locOf(start),
                    } });
                }
            }
        }

        // `[T, U, …]` or `[T]` one-tuple
        var elems: std.ArrayList(*Node) = .empty;
        while (true) {
            try elems.append(self.arena, try parseType(self));
            if (self.checkDelim(",")) {
                _ = self.advance();
                if (self.checkDelim("]")) break; // trailing comma
                continue;
            }
            break;
        }
        _ = try self.consume(.delimiter, "Expected ']' in tuple type", "]");
        return self.create(.{ .tuple_type = .{
            .elems = try elems.toOwnedSlice(self.arena),
            .loc = self.locOf(start),
        } });
    }

    return parseTypeAtom(self);
}

fn parseTypeAtom(self: *Parser) ParseError!*Node {
    const peek = self.peek(0) orelse return self.failMsg("Expected type name");

    // `{ field: T; … }` object / shape type (type position only — not an expression block).
    if (peek.type == .delimiter and std.mem.eql(u8, peek.value, "{")) {
        return parseShapeType(self);
    }

    // `@func(T, U): R` — types only (no param names). Named `@func foo` is a declaration.
    if (peek.type == .compiler_keyword and std.mem.eql(u8, peek.value, "func")) {
        if (self.peek(1)) |next| {
            if (next.type == .delimiter and std.mem.eql(u8, next.value, "(")) {
                return parseFuncType(self);
            }
        }
        return self.failMsg("Expected '(' after @func in type position");
    }

    // Literal types: `"a"`, `0`, `0x10`, `true`, `false`
    if (peek.type == .string) {
        const tok = self.advance().?;
        return self.create(.{ .literal = .{
            .literal_type = .string,
            .value = try self.dupe(tok.value),
            .loc = self.locOf(tok),
        } });
    }
    if (peek.type == .number or peek.type == .hex or peek.type == .octal or peek.type == .binary) {
        const tok = self.advance().?;
        const kind: ast.LiteralKind = switch (peek.type) {
            .hex => .hex,
            .octal => .octal,
            .binary => .binary,
            else => .number,
        };
        return self.create(.{ .literal = .{
            .literal_type = kind,
            .value = try self.dupe(tok.value),
            .loc = self.locOf(tok),
        } });
    }
    if (peek.type == .boolean) {
        const tok = self.advance().?;
        return self.create(.{ .literal = .{
            .literal_type = .boolean,
            .value = try self.dupe(tok.value),
            .loc = self.locOf(tok),
        } });
    }
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
    // `mem.Arena`, `lib.Point`, `ExprKind.Literal`
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

/// `{ name: Type; … }` — same field syntax as `@struct`, no methods.
fn parseShapeType(self: *Parser) ParseError!*Node {
    const start = self.advance().?; // `{`
    var fields: std.ArrayList(ast.ShapeField) = .empty;

    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const field_name = try self.consume(.identifier, "Expected field name in shape type", null);
        _ = try self.consume(.delimiter, "Expected ':' after field name", ":");
        const field_type = try parseType(self);
        _ = try self.consume(.delimiter, "Expected ';' after field in shape type", ";");
        try fields.append(self.arena, .{
            .name = try self.dupe(field_name.value),
            .type_annotation = field_type,
        });
    }

    _ = try self.consume(.delimiter, "Expected '}' after shape type", "}");
    return self.create(.{ .shape_type = .{
        .fields = try fields.toOwnedSlice(self.arena),
        .loc = self.locOf(start),
    } });
}

/// `@func(T, U, ...V): R` — parameter types only; `...` marks the last param as rest.
fn parseFuncType(self: *Parser) ParseError!*Node {
    const start = self.advance().?; // `@func`
    _ = try self.consume(.delimiter, "Expected '(' after @func", "(");

    var params: std.ArrayList(*Node) = .empty;
    var is_variadic = false;

    if (!self.checkDelim(")")) {
        while (true) {
            if (self.checkDelim("...")) {
                _ = self.advance();
                is_variadic = true;
            }
            const ty = try parseType(self);
            try params.append(self.arena, ty);
            if (is_variadic) {
                _ = try self.consume(.delimiter, "Expected ')' after variadic parameter type", ")");
                break;
            }
            if (self.checkDelim(",")) {
                _ = self.advance();
                continue;
            }
            _ = try self.consume(.delimiter, "Expected ',' or ')' in function type", ")");
            break;
        }
    } else {
        _ = self.advance();
    }

    var return_type: ?*Node = null;
    if (self.checkDelim(":")) {
        _ = self.advance();
        return_type = try parseType(self);
    }

    return self.create(.{ .func_type = .{
        .params = try params.toOwnedSlice(self.arena),
        .return_type = return_type,
        .is_variadic = is_variadic,
        .loc = self.locOf(start),
    } });
}
