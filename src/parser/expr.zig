const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const precedence = @import("../shared/precedence.zig");
const types = @import("types.zig");
const control = @import("control.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

pub fn parseExpression(self: *Parser) ParseError!*Node {
    return parseAssignment(self);
}

fn parseAssignment(self: *Parser) ParseError!*Node {
    const left = try parseBinary(self, 0);
    const tok = self.peek(0) orelse return left;
    if (tok.type == .assign_op) {
        _ = self.advance();
        const right = try parseAssignment(self);
        return self.create(.{ .assignment = .{
            .left = left,
            .operator = try self.dupe(tok.value),
            .right = right,
            .loc = left.loc(),
        } });
    }
    return left;
}

fn parseBinary(self: *Parser, min_prec: i32) ParseError!*Node {
    return parseBinaryInternal(self, min_prec, true);
}

fn parseBinaryInternal(self: *Parser, min_prec: i32, allow_range: bool) ParseError!*Node {
    var left = try parseUnary(self);
    while (true) {
        const tok = self.peek(0) orelse break;
        if (tok.type != .bin_op) break;
        if (!allow_range and std.mem.eql(u8, tok.value, "..")) break;
        const prec = precedence.PRECEDENCE.of(tok.value);
        if (prec < 0 or prec < min_prec) break;
        _ = self.advance();
        const right = try parseBinaryInternal(self, prec + 1, allow_range);
        left = try self.create(.{ .binary = .{
            .left = left,
            .operator = try self.dupe(tok.value),
            .right = right,
            .loc = left.loc(),
        } });
    }
    return left;
}

fn parseUnary(self: *Parser) ParseError!*Node {
    const tok = self.peek(0) orelse return parsePostfix(self);
    if (tok.type == .unary_op) {
        _ = self.advance();
        const arg = try parseUnary(self);
        return self.create(.{ .unary = .{
            .operator = try self.dupe(tok.value),
            .arg = arg,
            .loc = arg.loc(),
        } });
    }
    if (tok.type == .bin_op and (std.mem.eql(u8, tok.value, "+") or std.mem.eql(u8, tok.value, "-") or
        std.mem.eql(u8, tok.value, "~") or std.mem.eql(u8, tok.value, "&")))
    {
        _ = self.advance();
        const arg = try parseUnary(self);
        return self.create(.{ .unary = .{
            .operator = try self.dupe(tok.value),
            .arg = arg,
            .loc = arg.loc(),
        } });
    }
    // `const "x"` / `const [1, "a"]` — keep singleton / deep literal types.
    if (tok.type == .keyword and std.mem.eql(u8, tok.value, "const")) {
        _ = self.advance();
        const arg = try parseUnary(self);
        return self.create(.{ .unary = .{
            .operator = try self.dupe("const"),
            .arg = arg,
            .loc = arg.loc(),
        } });
    }
    return parsePostfix(self);
}

fn parsePostfix(self: *Parser) ParseError!*Node {
    var e = try parsePrimary(self);
    while (true) {
        const tok = self.peek(0) orelse break;
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "(")) {
            e = try finishCall(self, e);
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, ".")) {
            _ = self.advance();
            // Tuple fields `.0` / `.1` use number tokens; structs use identifiers.
            const prop = self.peek(0) orelse return self.failMsg("Expected property name");
            if (prop.type == .number or prop.type == .hex or prop.type == .octal or prop.type == .binary) {
                _ = self.advance();
                const prop_node = try self.create(.{ .primary = .{
                    .kind = .identifier,
                    .name = try self.dupe(prop.value),
                    .loc = self.locOf(prop),
                } });
                e = try self.create(.{ .member = .{
                    .object = e,
                    .property = prop_node,
                    .loc = e.loc(),
                } });
                continue;
            }
            const prop_tok = try self.consume(.identifier, "Expected property name", null);
            const prop_node = try self.create(.{ .primary = .{
                .kind = .identifier,
                .name = try self.dupe(prop_tok.value),
                .loc = self.locOf(prop_tok),
            } });
            e = try self.create(.{ .member = .{
                .object = e,
                .property = prop_node,
                .loc = e.loc(),
            } });
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "[")) {
            const start_tok = tok;
            _ = self.advance();
            // Bounds must not consume `..` (range is slice syntax here, not a binary expr).
            var start_expr: ?*Node = null;
            var end_expr: ?*Node = null;
            var is_slice = false;

            if (self.check(.bin_op) and self.peek(0) != null and std.mem.eql(u8, self.peek(0).?.value, "..")) {
                // `[..j]` or `[..]`
                is_slice = true;
                _ = self.advance(); // '..'
                if (!(self.checkDelim("]"))) {
                    end_expr = try parseBinaryInternal(self, 0, false);
                }
            } else {
                start_expr = try parseBinaryInternal(self, 0, false);
                if (self.check(.bin_op) and self.peek(0) != null and std.mem.eql(u8, self.peek(0).?.value, "..")) {
                    is_slice = true;
                    _ = self.advance(); // '..'
                    if (!(self.checkDelim("]"))) {
                        end_expr = try parseBinaryInternal(self, 0, false);
                    }
                }
            }
            _ = try self.consume(.delimiter, "Expected ']'", "]");
            if (!is_slice and start_expr == null) {
                return self.failTok(start_tok, "Expected index expression", .{});
            }
            e = try self.create(.{ .index = .{
                .object = e,
                .index = start_expr,
                .end = end_expr,
                .is_slice = is_slice,
                .loc = e.loc(),
            } });
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "{")) {
            if (e.* == .primary or e.* == .member) {
                e = try finishStructInit(self, e, tok);
                continue;
            }
        }
        // `.?` assertion-unwrap: panics if the value is null, otherwise unwraps.
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, ".?")) {
            _ = self.advance();
            e = try self.create(.{ .unwrap_expr = .{ .expression = e, .loc = e.loc() } });
            continue;
        }
        if (tok.type == .delimiter and std.mem.eql(u8, tok.value, "?")) {
            _ = self.advance();
            e = try self.create(.{ .try_expr = .{ .expression = e, .loc = e.loc() } });
            continue;
        }
        break;
    }
    return e;
}

fn finishStructInit(self: *Parser, type_expr: *Node, tok: ctx.Token) ParseError!*Node {
    _ = self.advance(); // '{'
    var fields: std.ArrayList(ast.StructFieldInit) = .empty;
    while (!self.isAtEnd() and !self.checkDelim("}")) {
        const field_name = try self.consume(.identifier, "Expected field name in struct initialization", null);
        _ = try self.consume(.delimiter, "Expected ':' after field name", ":");
        const field_value = try parseExpression(self);
        try fields.append(self.arena, .{
            .name = try self.dupe(field_name.value),
            .value = field_value,
        });
        if (self.checkDelim(",")) {
            _ = self.advance();
        } else break;
    }
    _ = try self.consume(.delimiter, "Expected '}' after struct initialization", "}");
    return self.create(.{ .struct_init = .{
        .type_expr = type_expr,
        .fields = try fields.toOwnedSlice(self.arena),
        .loc = self.locOf(tok),
    } });
}

/// `{ ident: …` — object/struct field init, not a block.
pub fn looksLikeFieldInitObject(self: *const Parser) bool {
    const brace = self.peek(0) orelse return false;
    if (brace.type != .delimiter or !std.mem.eql(u8, brace.value, "{")) return false;
    const name = self.peek(1) orelse return false;
    if (name.type != .identifier) return false;
    const colon = self.peek(2) orelse return false;
    return colon.type == .delimiter and std.mem.eql(u8, colon.value, ":");
}

/// `Type { f: v, … }` with an already-parsed type node (e.g. `$p: Point = { … }`).
pub fn parseStructInitWithType(self: *Parser, type_expr: *Node) ParseError!*Node {
    const tok = self.peek(0) orelse return self.failMsg("Expected '{' for object initialization");
    if (tok.type != .delimiter or !std.mem.eql(u8, tok.value, "{")) {
        return self.failTok(tok, "Expected '{{' for object initialization", .{});
    }
    return finishStructInit(self, type_expr, tok);
}

pub fn finishCall(self: *Parser, callee: *Node) ParseError!*Node {
    _ = try self.consume(.delimiter, "Expected '('", "(");
    if (callee.* == .primary and std.mem.eql(u8, callee.primary.name, "@asm") and
        !self.check(.string) and !self.check(.template))
    {
        return finishExtendedAsmCall(self, callee);
    }
    var args: std.ArrayList(*Node) = .empty;
    if (!self.checkDelim(")")) {
        while (true) {
            try args.append(self.arena, try parseExpression(self));
            if (self.checkDelim(",")) {
                _ = self.advance();
            } else break;
        }
    }
    _ = try self.consume(.delimiter, "Expected ')'", ")");
    return self.create(.{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(self.arena),
        .loc = callee.loc(),
    } });
}

const AsmSections = struct {
    template: []const u8,
    outputs: []const u8,
    inputs: []const u8,
    clobbers: []const u8,
};

const AsmTextCursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *AsmTextCursor) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn consume(self: *AsmTextCursor, c: u8) bool {
        self.skipSpace();
        if (self.pos >= self.text.len or self.text[self.pos] != c) return false;
        self.pos += 1;
        return true;
    }

    fn done(self: *AsmTextCursor) bool {
        self.skipSpace();
        return self.pos == self.text.len;
    }
};

fn finishExtendedAsmCall(self: *Parser, callee: *Node) ParseError!*Node {
    var args: std.ArrayList(*Node) = .empty;
    try args.append(self.arena, try parseExpression(self));
    if (self.checkDelim(")")) {
        _ = self.advance();
        return self.create(.{ .call = .{
            .callee = callee,
            .args = try args.toOwnedSlice(self.arena),
            .loc = callee.loc(),
        } });
    }
    _ = try self.consume(.delimiter, "Expected ',' after @asm result type", ",");

    const template_tok = try self.consume(.template, "Expected a fenced assembly template", null);
    const encoded = try encodeAsmTemplate(self, template_tok, &args);
    const sections = try splitAsmSections(self, template_tok, encoded);

    var outputs: std.ArrayList(ast.AsmOutput) = .empty;
    var inputs: std.ArrayList(ast.AsmInput) = .empty;
    var clobbers: std.ArrayList([]const u8) = .empty;
    try parseAsmOutputs(self, template_tok, sections.outputs, args.items.len, &outputs);
    try parseAsmInputs(self, template_tok, sections.inputs, args.items.len, &inputs);
    try parseAsmClobbers(self, template_tok, sections.clobbers, &clobbers);
    try validateAsmOperandNames(self, template_tok, outputs.items, inputs.items);

    _ = try self.consume(.delimiter, "Expected ')' after @asm template", ")");
    return self.create(.{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(self.arena),
        .inline_asm = .{
            .template = try cookTemplateText(self, std.mem.trim(u8, sections.template, "\r\n")),
            .outputs = try outputs.toOwnedSlice(self.arena),
            .inputs = try inputs.toOwnedSlice(self.arena),
            .clobbers = try clobbers.toOwnedSlice(self.arena),
        },
        .loc = callee.loc(),
    } });
}

fn encodeAsmTemplate(self: *Parser, token: ctx.Token, args: *std.ArrayList(*Node)) ParseError![]const u8 {
    const parts = token.template_parts orelse return self.failTok(token, "Assembly template is missing parts", .{});
    var encoded: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        if (!part.is_hole) {
            try encoded.appendSlice(self.arena, part.value);
            continue;
        }
        const node = try parseHoleExpression(self, part.value, .{
            .line = part.line,
            .column = part.column,
            .path = self.path,
        });
        const arg_index = args.items.len;
        try args.append(self.arena, node);
        try encoded.writer(self.arena).print("__LLTS_ASM_HOLE_{d}__", .{arg_index});
    }
    return encoded.toOwnedSlice(self.arena) catch return error.OutOfMemory;
}

fn splitAsmSections(self: *Parser, token: ctx.Token, text: []const u8) ParseError!AsmSections {
    var line_starts: [3]usize = undefined;
    var colons: [3]usize = undefined;
    var count: usize = 0;
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        var first = line_start;
        while (first < line_end and (text[first] == ' ' or text[first] == '\t' or text[first] == '\r')) first += 1;
        if (first < line_end and text[first] == ':') {
            if (count == 3) return self.failTok(token, "@asm expects exactly three ':' operand sections", .{});
            line_starts[count] = line_start;
            colons[count] = first;
            count += 1;
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    if (count != 3) {
        return self.failTok(token, "Extended @asm requires output, input, and clobber sections on separate ':' lines", .{});
    }
    return .{
        .template = text[0..line_starts[0]],
        .outputs = text[colons[0] + 1 .. line_starts[1]],
        .inputs = text[colons[1] + 1 .. line_starts[2]],
        .clobbers = text[colons[2] + 1 ..],
    };
}

fn parseAsmOutputs(
    self: *Parser,
    token: ctx.Token,
    text: []const u8,
    arg_count: usize,
    outputs: *std.ArrayList(ast.AsmOutput),
) ParseError!void {
    var cur = AsmTextCursor{ .text = text };
    while (!cur.done()) {
        const name = try parseAsmName(self, token, &cur);
        const constraint = try parseAsmQuoted(self, token, &cur, "output constraint");
        if (!cur.consume('(')) return self.failTok(token, "Expected '(' after @asm output constraint", .{});
        cur.skipSpace();
        var output = ast.AsmOutput{ .name = name, .constraint = constraint };
        if (std.mem.startsWith(u8, cur.text[cur.pos..], "->")) {
            cur.pos += 2;
            const type_start = cur.pos;
            while (cur.pos < cur.text.len and cur.text[cur.pos] != ')') cur.pos += 1;
            if (cur.pos == cur.text.len) return self.failTok(token, "Unterminated @asm return output", .{});
            const return_type = std.mem.trim(u8, cur.text[type_start..cur.pos], " \t\r\n");
            if (return_type.len == 0) return self.failTok(token, "@asm return output requires a type", .{});
            output.return_type = try self.dupe(return_type);
        } else {
            output.arg_index = try parseAsmHoleIndex(self, token, &cur, arg_count, name);
        }
        if (!cur.consume(')')) return self.failTok(token, "Expected ')' after @asm output", .{});
        try outputs.append(self.arena, output);
        if (cur.done()) break;
        if (!cur.consume(',')) return self.failTok(token, "Expected ',' between @asm outputs", .{});
    }
}

fn parseAsmInputs(
    self: *Parser,
    token: ctx.Token,
    text: []const u8,
    arg_count: usize,
    inputs: *std.ArrayList(ast.AsmInput),
) ParseError!void {
    var cur = AsmTextCursor{ .text = text };
    while (!cur.done()) {
        const name = try parseAsmName(self, token, &cur);
        const constraint = try parseAsmQuoted(self, token, &cur, "input constraint");
        if (!cur.consume('(')) return self.failTok(token, "Expected '(' after @asm input constraint", .{});
        const arg_index = try parseAsmHoleIndex(self, token, &cur, arg_count, name);
        if (!cur.consume(')')) return self.failTok(token, "Expected ')' after @asm input", .{});
        try inputs.append(self.arena, .{ .name = name, .constraint = constraint, .arg_index = arg_index });
        if (cur.done()) break;
        if (!cur.consume(',')) return self.failTok(token, "Expected ',' between @asm inputs", .{});
    }
}

fn parseAsmClobbers(
    self: *Parser,
    token: ctx.Token,
    text: []const u8,
    clobbers: *std.ArrayList([]const u8),
) ParseError!void {
    var cur = AsmTextCursor{ .text = text };
    while (!cur.done()) {
        const clobber = try parseAsmQuoted(self, token, &cur, "clobber");
        if (clobber.len == 0 or std.ascii.isDigit(clobber[0])) {
            return self.failTok(token, "Invalid @asm clobber '{s}'", .{clobber});
        }
        for (clobber) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                return self.failTok(token, "Invalid @asm clobber '{s}'", .{clobber});
            }
        }
        try clobbers.append(self.arena, clobber);
        if (cur.done()) break;
        if (!cur.consume(',')) return self.failTok(token, "Expected ',' between @asm clobbers", .{});
    }
}

fn parseAsmName(self: *Parser, token: ctx.Token, cur: *AsmTextCursor) ParseError![]const u8 {
    if (!cur.consume('[')) return self.failTok(token, "Expected '[name]' in @asm operand", .{});
    const start = cur.pos;
    if (start >= cur.text.len or (!std.ascii.isAlphabetic(cur.text[start]) and cur.text[start] != '_')) {
        return self.failTok(token, "Invalid @asm operand name", .{});
    }
    while (cur.pos < cur.text.len and
        (std.ascii.isAlphanumeric(cur.text[cur.pos]) or cur.text[cur.pos] == '_')) cur.pos += 1;
    const end = cur.pos;
    if (end == start or !cur.consume(']')) return self.failTok(token, "Invalid @asm operand name", .{});
    return self.dupe(cur.text[start..end]);
}

fn parseAsmQuoted(
    self: *Parser,
    token: ctx.Token,
    cur: *AsmTextCursor,
    what: []const u8,
) ParseError![]const u8 {
    cur.skipSpace();
    if (cur.pos >= cur.text.len or cur.text[cur.pos] != '"') {
        return self.failTok(token, "Expected quoted @asm {s}", .{what});
    }
    cur.pos += 1;
    const start = cur.pos;
    while (cur.pos < cur.text.len and cur.text[cur.pos] != '"') {
        if (cur.text[cur.pos] == '\n' or cur.text[cur.pos] == '\r') {
            return self.failTok(token, "Newline in @asm {s}", .{what});
        }
        cur.pos += 1;
    }
    if (cur.pos == cur.text.len) return self.failTok(token, "Unterminated quoted @asm {s}", .{what});
    const value = try self.dupe(cur.text[start..cur.pos]);
    cur.pos += 1;
    return value;
}

/// Parse an internal `${expr}` hole placeholder inside an extended `@asm` operand list.
/// If a raw constant or literal expression was written instead of a `${...}` hole, provide
/// targeted diagnostic feedback explaining how to bind the constant to a local variable.
fn parseAsmHoleIndex(
    self: *Parser,
    token: ctx.Token,
    cur: *AsmTextCursor,
    arg_count: usize,
    operand_name: []const u8,
) ParseError!usize {
    const prefix = "__LLTS_ASM_HOLE_";
    const suffix = "__";
    cur.skipSpace();
    if (!std.mem.startsWith(u8, cur.text[cur.pos..], prefix)) {
        return self.failTok(
            token,
            "@asm operand '{s}' must be written as '${{expr}}'; bind constants to a variable first, e.g. '$nr: i64 = 1;' then '(${{nr}})'",
            .{operand_name},
        );
    }
    cur.pos += prefix.len;
    const start = cur.pos;
    while (cur.pos < cur.text.len and std.ascii.isDigit(cur.text[cur.pos])) cur.pos += 1;
    if (cur.pos == start or !std.mem.startsWith(u8, cur.text[cur.pos..], suffix)) {
        return self.failTok(token, "Invalid @asm operand hole", .{});
    }
    const index = std.fmt.parseInt(usize, cur.text[start..cur.pos], 10) catch
        return self.failTok(token, "Invalid @asm operand hole index", .{});
    cur.pos += suffix.len;
    if (index == 0 or index >= arg_count) return self.failTok(token, "Invalid @asm operand hole index", .{});
    return index;
}

fn validateAsmOperandNames(
    self: *Parser,
    token: ctx.Token,
    outputs: []const ast.AsmOutput,
    inputs: []const ast.AsmInput,
) ParseError!void {
    for (outputs, 0..) |output, i| {
        for (outputs[0..i]) |other| {
            if (std.mem.eql(u8, output.name, other.name)) return self.failTok(token, "Duplicate @asm operand name '{s}'", .{output.name});
        }
    }
    for (inputs, 0..) |input, i| {
        for (outputs) |output| {
            if (std.mem.eql(u8, input.name, output.name)) return self.failTok(token, "Duplicate @asm operand name '{s}'", .{input.name});
        }
        for (inputs[0..i]) |other| {
            if (std.mem.eql(u8, input.name, other.name)) return self.failTok(token, "Duplicate @asm operand name '{s}'", .{input.name});
        }
    }
}

pub fn parsePrimary(self: *Parser) ParseError!*Node {
    const token = self.peek(0) orelse return self.failMsg("Unexpected end of expression");
    switch (token.type) {
        .boolean, .string, .number, .hex, .binary, .octal => return parseLiteral(self),
        .template => return parseTemplate(self, token),
        .keyword => {
            if (std.mem.eql(u8, token.value, "error")) {
                _ = self.advance();
                _ = try self.consume(.delimiter, "Expected '(' after error", "(");
                var args: std.ArrayList(*Node) = .empty;
                if (!self.checkDelim(")")) {
                    while (true) {
                        try args.append(self.arena, try parseExpression(self));
                        if (self.checkDelim(",")) {
                            _ = self.advance();
                        } else break;
                    }
                }
                _ = try self.consume(.delimiter, "Expected ')' after error(...)", ")");
                return self.create(.{ .error_expr = .{
                    .args = try args.toOwnedSlice(self.arena),
                    .loc = self.locOf(token),
                } });
            }
            if (std.mem.eql(u8, token.value, "null")) {
                _ = self.advance();
                return self.create(.{ .literal = .{
                    .literal_type = .null,
                    .value = try self.dupe("null"),
                    .loc = self.locOf(token),
                } });
            }
        },
        .compiler_keyword => {
            if (std.mem.eql(u8, token.value, "if")) {
                _ = self.advance();
                return control.parseIfExpression(self);
            }
            if (std.mem.eql(u8, token.value, "switch")) {
                _ = self.advance();
                return control.parseSwitchExpression(self);
            }
            if (std.mem.eql(u8, token.value, "for")) {
                _ = self.advance();
                return control.parseForExpression(self);
            }
            if (std.mem.eql(u8, token.value, "comptime")) {
                const comptime_tok = token;
                _ = self.advance();
                const next = self.peek(0) orelse return self.failMsg("Expected block or expression after @comptime");
                const inner = if (next.type == .delimiter and std.mem.eql(u8, next.value, "{"))
                    try control.parseBlock(self)
                else
                    try parseExpression(self);
                return self.create(.{ .comptime_expr = .{
                    .expr = inner,
                    .loc = self.locOf(comptime_tok),
                } });
            }
            _ = self.advance();
            const name = try std.fmt.allocPrint(self.arena, "@{s}", .{token.value});
            return self.create(.{ .primary = .{
                .kind = .identifier,
                .name = name,
                .loc = self.locOf(token),
            } });
        },
        .identifier => {
            if (self.peek(1)) |n| {
                if (n.type == .delimiter and std.mem.eql(u8, n.value, ":")) {
                    if (self.peek(2)) |n2| {
                        if (n2.type == .delimiter and std.mem.eql(u8, n2.value, "{")) {
                            const label = token.value;
                            _ = self.advance();
                            _ = self.advance();
                            return control.parseLabeledBlock(self, label);
                        }
                    }
                }
            }
            _ = self.advance();
            return self.create(.{ .primary = .{
                .kind = .identifier,
                .name = try self.dupe(token.value),
                .loc = self.locOf(token),
            } });
        },
        .v_register => return self.rejectRegisterSigil(token, self.peek(1)),
        .delimiter => {
            if (std.mem.eql(u8, token.value, "(")) {
                _ = self.advance();
                const inner = try parseExpression(self);
                _ = try self.consume(.delimiter, "Expected ')'", ")");
                return inner;
            }
            if (std.mem.eql(u8, token.value, "[")) return parseBracketPrimary(self, token);
            if (std.mem.eql(u8, token.value, "{")) return control.parseBlock(self);
            if (std.mem.eql(u8, token.value, "?") and looksLikeTypeContinuation(self.peek(1))) {
                return types.parseType(self);
            }
        },
        .bin_op => {
            // `*T` as a type expression (e.g. `@sizeOf(*Point)`).
            if (std.mem.eql(u8, token.value, "*") and looksLikeTypeContinuation(self.peek(1))) {
                return types.parseType(self);
            }
        },
        else => {},
    }
    return self.failTok(token, "Unexpected token in expression: '{s}'", .{token.value});
}

/// `[` … `]` in expression position: array type (`[]T`, `[N]T`) or array literal (`[1, 2]`).
fn parseBracketPrimary(self: *Parser, token: ctx.Token) ParseError!*Node {
    const t1 = self.peek(1) orelse return parseArrayLiteral(self, token);

    // `[]T` vs `[]`
    if (t1.type == .delimiter and std.mem.eql(u8, t1.value, "]")) {
        if (looksLikeTypeContinuation(self.peek(2))) return types.parseType(self);
        return parseArrayLiteral(self, token);
    }

    // `[N]T` vs `[N]` / `[N, …]`
    if (isArrayLengthToken(t1)) {
        const t2 = self.peek(2) orelse return parseArrayLiteral(self, token);
        if (t2.type == .delimiter and std.mem.eql(u8, t2.value, "]")) {
            if (looksLikeTypeContinuation(self.peek(3))) return types.parseType(self);
        }
    }

    return parseArrayLiteral(self, token);
}

fn isArrayLengthToken(tok: ctx.Token) bool {
    return tok.type == .number or tok.type == .hex or tok.type == .binary or tok.type == .octal;
}

fn looksLikeTypeContinuation(tok: ?ctx.Token) bool {
    const t = tok orelse return false;
    if (t.type == .delimiter and (std.mem.eql(u8, t.value, "[") or std.mem.eql(u8, t.value, "?"))) return true;
    if (t.type == .bin_op and std.mem.eql(u8, t.value, "*")) return true;
    if (t.type == .identifier) return true;
    return t.type == .keyword and (std.mem.eql(u8, t.value, "error") or std.mem.eql(u8, t.value, "null"));
}

fn parseArrayLiteral(self: *Parser, token: ctx.Token) ParseError!*Node {
    _ = self.advance();
    var elements: std.ArrayList(*Node) = .empty;
    if (!self.checkDelim("]")) {
        while (true) {
            try elements.append(self.arena, try parseExpression(self));
            if (self.checkDelim(",")) {
                _ = self.advance();
                if (self.checkDelim("]")) break; // trailing comma
                continue;
            }
            break;
        }
    }
    _ = try self.consume(.delimiter, "Expected ']'", "]");
    return self.create(.{ .array_literal = .{
        .elements = try elements.toOwnedSlice(self.arena),
        .loc = self.locOf(token),
    } });
}

fn parseLiteral(self: *Parser) ParseError!*Node {
    const token = self.advance() orelse return error.ParseFailed;
    const kind: ast.LiteralKind = switch (token.type) {
        .boolean => .boolean,
        .string => .string,
        .hex => .hex,
        .binary => .binary,
        .octal => .octal,
        .number => .number,
        else => return self.failTok(token, "Invalid literal '{s}'", .{token.value}),
    };
    return self.create(.{ .literal = .{
        .literal_type = kind,
        .value = try self.dupe(token.value),
        .loc = self.locOf(token),
    } });
}

/// Cook template-body escapes (same set as `"…"` plus `\$` → `$`).
fn cookTemplateText(self: *Parser, raw: []const u8) ParseError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const esc = raw[i + 1];
            switch (esc) {
                'n' => try buf.append(self.arena, '\n'),
                'r' => try buf.append(self.arena, '\r'),
                't' => try buf.append(self.arena, '\t'),
                '\\' => try buf.append(self.arena, '\\'),
                '"' => try buf.append(self.arena, '"'),
                '\'' => try buf.append(self.arena, '\''),
                '$' => try buf.append(self.arena, '$'),
                else => {
                    try buf.append(self.arena, '\\');
                    try buf.append(self.arena, esc);
                },
            }
            i += 2;
            continue;
        }
        try buf.append(self.arena, raw[i]);
        i += 1;
    }
    return buf.toOwnedSlice(self.arena) catch return error.OutOfMemory;
}

fn stringLiteralNode(self: *Parser, value: []const u8, loc: ast.Location) ParseError!*Node {
    const owned = try self.dupe(value);
    return self.create(.{ .literal = .{
        .literal_type = .string,
        .value = owned,
        .loc = loc,
    } });
}

/// Parse a fenced template token and desugar to a left-folded `@concat(0, …, …)` chain.
fn parseTemplate(self: *Parser, token: ctx.Token) ParseError!*Node {
    _ = self.advance(); // consume .template
    const parts = token.template_parts orelse {
        return self.failTok(token, "internal: template token missing parts", .{});
    };

    var pieces: std.ArrayList(*Node) = .empty;
    const base_loc = self.locOf(token);
    var has_hole = false;

    for (parts) |part| {
        const part_loc = ast.Location{
            .line = part.line,
            .column = part.column,
            .path = self.path,
        };
        if (part.is_hole) {
            if (part.value.len == 0) {
                return self.failTokRaw(.{ .type = .template, .value = "", .line = part.line, .column = part.column },
                    \\empty `${}` interpolation
                    \\
                    \\help: put a single expression inside the braces:
                    \\
                    \\    ```
                    \\    hello ${name}
                    \\    ```;
                    \\
                    \\note: declarations (`$x = …`) are not allowed here; declare outside the template
                );
            }
            has_hole = true;
            const hole_node = try parseHoleExpression(self, part.value, part_loc);
            try pieces.append(self.arena, hole_node);
        } else {
            if (part.value.len == 0) continue;
            const cooked = try cookTemplateText(self, part.value);
            if (cooked.len == 0) continue;
            try pieces.append(self.arena, try stringLiteralNode(self, cooked, part_loc));
        }
    }

    if (pieces.items.len == 0) {
        return stringLiteralNode(self, "", base_loc);
    }
    // Pure text → string literal(s). Any `${…}` → `@concat(0, "", …)` so a lone
    // hole still yields a string (`${n}` → `@concat(0, "", n)`).
    if (pieces.items.len == 1 and !has_hole) {
        return pieces.items[0];
    }

    var acc = if (has_hole)
        try stringLiteralNode(self, "", base_loc)
    else
        pieces.items[0];
    const start: usize = if (has_hole) 0 else 1;
    for (pieces.items[start..]) |right| {
        acc = try concatCallNode(self, acc, right, base_loc);
    }
    return acc;
}

/// `@concat(0, left, right)` — `0` selects the current frame-backed concat
/// path until allocation moves to the standard library.
fn concatCallNode(self: *Parser, left: *Node, right: *Node, loc: ast.Location) ParseError!*Node {
    const callee = try self.create(.{ .primary = .{
        .name = try self.dupe("@concat"),
        .kind = .identifier,
        .loc = loc,
    } });
    const zero = try self.create(.{ .literal = .{
        .value = try self.dupe("0"),
        .literal_type = .number,
        .loc = loc,
    } });
    const args = try self.arena.alloc(*Node, 3);
    args[0] = zero;
    args[1] = left;
    args[2] = right;
    return self.create(.{ .call = .{
        .callee = callee,
        .args = args,
        .loc = loc,
    } });
}

/// Tokenize and parse a single-expression `${…}` hole.
fn parseHoleExpression(self: *Parser, src: []const u8, loc: ast.Location) ParseError!*Node {
    const scanner = @import("../scanner/root.zig");
    const scan_result = scanner.scan(self.arena, src, self.path) catch {
        return self.failTokRaw(.{ .type = .template, .value = "", .line = loc.line, .column = loc.column },
            \\could not scan `${…}` interpolation
            \\
            \\help: a hole must be a single expression (call, identifier, literal, @if, …)
        );
    };

    // Offset hole token positions to the real source location.
    for (scan_result.tokens.items) |*t| {
        const rel_line = t.line;
        t.line = loc.line + rel_line - 1;
        if (rel_line == 1) {
            t.column = loc.column + t.column - 1;
        }
    }

    var hole_parser: Parser = .{
        .tokens = scan_result.tokens.items,
        .current = 0,
        .path = self.path,
        .source = self.source,
        .arena = self.arena,
        .diagnostics = self.diagnostics,
        .in_type_fn = self.in_type_fn,
    };

    if (hole_parser.isAtEnd()) {
        return self.failTokRaw(.{ .type = .template, .value = "", .line = loc.line, .column = loc.column },
            \\empty `${}` interpolation
            \\
            \\help: put a single expression inside the braces:
            \\
            \\    ```
            \\    hello ${name}
            \\    ```;
            \\
            \\note: declarations (`$x = …`) are not allowed here; declare outside the template
        );
    }

    const node = try parseExpression(&hole_parser);

    // A hole is a single expression — no statements, no `$` declarations, no `;`.
    if (!hole_parser.isAtEnd()) {
        const bad = hole_parser.peek(0).?;
        return hole_parser.failTokRaw(bad,
            \\unexpected token in `${…}` interpolation
            \\
            \\help: a hole holds exactly one expression, for example:
            \\
            \\    $name = "world";
            \\    $s = ```
            \\    hello ${name}
            \\    ```;
            \\
            \\note: no `;` inside ${} — declare `$` variables outside the template
            \\note: no multi-statement holes
            \\note: `"` / `'` strings and nested `{…}` inside a call are fine
        );
    }

    if (node.* == .assignment) {
        return self.failTokRaw(.{ .type = .template, .value = "", .line = node.loc().line, .column = node.loc().column },
            \\assignment is not allowed in `${…}`
            \\
            \\help: assign before the template, then interpolate the variable:
            \\
            \\    $name = "world";
            \\    $s = ```
            \\    hello ${name}
            \\    ```;
        );
    }

    if (node.* == .declaration) {
        return self.failTokRaw(.{ .type = .template, .value = "", .line = node.loc().line, .column = node.loc().column },
            \\variable declaration is not allowed in `${…}`
            \\
            \\help: declare outside the template, then interpolate:
            \\
            \\    $name = "world";
            \\    $s = ```
            \\    hello ${name}
            \\    ```;
        );
    }

    return node;
}
