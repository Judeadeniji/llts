const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");
const stmt = @import("stmt.zig");

pub const Document = ast.Document;
pub const ParseError = ctx.ParseError;
pub const Parser = ctx.Parser;

const decl = @import("decl.zig");
const expr = @import("expr.zig");
const control = @import("control.zig");
const types = @import("types.zig");
const structs = @import("structs.zig");

pub fn parse(
    allocator: std.mem.Allocator,
    tokens: []const ctx.Token,
    path: []const u8,
    source: []const u8,
) ParseError!Document {
    var doc: Document = .{
        .path = path,
        .source = source,
        .statements = &.{},
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer doc.deinit();

    var p: Parser = .{
        .tokens = tokens,
        .path = path,
        .source = source,
        .arena = doc.arena.allocator(),
    };

    doc.statements = try buildAst(&p);
    return doc;
}

fn buildAst(self: *Parser) ParseError![]*ast.Node {
    var list: std.ArrayList(*ast.Node) = .empty;
    while (!self.isAtEnd()) {
        const s = try stmt.parseStatement(self);
        try list.append(self.arena, s);
    }
    return list.toOwnedSlice(self.arena) catch return error.OutOfMemory;
}

// Re-exports for internal modules / tests
pub const parseStatement = stmt.parseStatement;
pub const parseExpression = expr.parseExpression;
pub const parseType = types.parseType;
pub const parseBlock = control.parseBlock;
pub const parseDeclaration = decl.parseDeclaration;
pub const parseCompilerStruct = structs.parseCompilerStruct;

test "parse simple declaration" {
    const scanner = @import("../scanner/root.zig");
    const src = "$x = 1;\n";
    var scan_result = try scanner.scan(std.testing.allocator, src, "t.lls");
    defer scanner.deinitScanResult(&scan_result);
    var doc = try parse(std.testing.allocator, scan_result.tokens.items, "t.lls", src);
    defer doc.deinit();
    try std.testing.expect(doc.statements.len == 1);
    try std.testing.expect(doc.statements[0].* == .declaration);
}

test "parse func if for and reject dollar" {
    const scanner = @import("../scanner/root.zig");
    const src =
        \\@func main() {
        \\  @if (true) { return 1; }
        \\  @for (0..3) |i| { }
        \\}
        \\
    ;
    var scan_result = try scanner.scan(std.testing.allocator, src, "t.lls");
    defer scanner.deinitScanResult(&scan_result);
    var doc = try parse(std.testing.allocator, scan_result.tokens.items, "t.lls", src);
    defer doc.deinit();
    try std.testing.expect(doc.statements[0].* == .function_decl);

    const bad = "$y;\n";
    var bad_scan = try scanner.scan(std.testing.allocator, bad, "t.lls");
    defer scanner.deinitScanResult(&bad_scan);
    try std.testing.expectError(error.ParseFailed, parse(std.testing.allocator, bad_scan.tokens.items, "t.lls", bad));
}
