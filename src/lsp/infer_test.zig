//! Unit tests for infer.zig: formatType, evalConstant (exercised through
//! formatType's is_const path), and findDeclarationInAst.
//! Parsed with the real scanner+parser so the tests break if the AST changes.

const std = @import("std");
const llts = @import("llts");
const ast = llts.ast;
const infer = @import("infer.zig");

const testing = std.testing;

fn parseDoc(alloc: std.mem.Allocator, src: []const u8) !ast.Document {
    const scan = try llts.scanner.scan(alloc, src, "test.lls");
    return llts.parser.parse(alloc, scan.tokens.items, "test.lls", src, null);
}

/// Find the first top-level statement declaring `name`.
fn findTopLevel(doc: *const ast.Document, name: []const u8) ?*ast.Node {
    for (doc.statements) |stmt| {
        const matches = switch (stmt.*) {
            .declaration => |d| std.mem.eql(u8, d.name, name),
            .function_decl => |f| std.mem.eql(u8, f.name, name),
            .struct_decl => |s| std.mem.eql(u8, s.name, name),
            .enum_decl => |e| std.mem.eql(u8, e.name, name),
            .type_decl => |t| std.mem.eql(u8, t.name, name),
            else => false,
        };
        if (matches) return stmt;
    }
    return null;
}

// --- formatType ------------------------------------------------------------

test "formatType int literal const" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@const $x = 42;\n");
    const decl = findTopLevel(&doc, "x") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("42 (int)", s);
}

test "formatType boolean literal const" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@const $flag = true;\n");
    const decl = findTopLevel(&doc, "flag") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("true (bool)", s);
}

test "formatType string literal const" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@const $greeting = \"hi\";\n");
    const decl = findTopLevel(&doc, "greeting") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("\"hi\" ([]byte)", s);
}

test "formatType const-folds arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@const $x = 6 * 7;\n");
    const decl = findTopLevel(&doc, "x") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("42 (int)", s);
}

test "formatType const references another const" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@const $a = 5;
        \\@const $b = a + 2;
        \\
    );
    const decl = findTopLevel(&doc, "b") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("7 (int)", s);
}

test "formatType division truncates and rejects div by zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@const $q = 7 / 2;
        \\@const $bad = 1 / 0;
        \\
    );
    const q = findTopLevel(&doc, "q") orelse return error.NoDecl;
    const q_str = infer.formatType(arena.allocator(), q, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("3 (int)", q_str);

    const bad = findTopLevel(&doc, "bad") orelse return error.NoDecl;
    // Div by zero is not foldable: falls back to the raw literal form.
    const bad_str = infer.formatType(arena.allocator(), bad, true, &doc);
    try testing.expect(bad_str == null or std.mem.indexOf(u8, bad_str.?, "1") != null);
}

test "formatType comparison folds to bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@const $c = 3 < 10;\n");
    const decl = findTopLevel(&doc, "c") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("true (bool)", s);
}

test "formatType string equality folds to bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@const $same = "ab" == "ab";
        \\@const $diff = "ab" == "cd";
        \\
    );
    const same = findTopLevel(&doc, "same") orelse return error.NoDecl;
    const s1 = infer.formatType(arena.allocator(), same, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("true (bool)", s1);

    const diff = findTopLevel(&doc, "diff") orelse return error.NoDecl;
    const s2 = infer.formatType(arena.allocator(), diff, true, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("false (bool)", s2);
}

test "formatType function signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@func add(a: i32, b: i32): i32 {
        \\    return a + b;
        \\}
        \\
    );
    const func = findTopLevel(&doc, "add") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), func, false, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("@func add(a: i32, b: i32): i32", s);
}

test "formatType untyped params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@func add(x, y) {
        \\    return x + y;
        \\}
        \\
    );
    const func = findTopLevel(&doc, "add") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), func, false, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("@func add(x, y)", s);
}

test "formatType struct with fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@struct Point {
        \\    x: int;
        \\    y: int;
        \\}
        \\
    );
    const decl = findTopLevel(&doc, "Point") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, false, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("@struct Point { x: int, y: int }", s);
}

test "formatType enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@enum Color {
        \\    Red,
        \\    Green,
        \\}
        \\
    );
    const decl = findTopLevel(&doc, "Color") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, false, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("@enum Color", s);
}

test "formatType type decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@type UserId = i32;\n");
    const decl = findTopLevel(&doc, "UserId") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, false, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("@type UserId = i32", s);
}

test "formatType non-const declaration uses initializer type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "$n = 5;\n");
    const decl = findTopLevel(&doc, "n") orelse return error.NoDecl;
    const s = infer.formatType(arena.allocator(), decl, false, &doc) orelse return error.NoFormat;
    try testing.expectEqualStrings("int", s);
}

// --- findDeclarationInAst --------------------------------------------------

test "findDeclaration finds global const" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@const $x = 1;
        \\@func main() {}
        \\
    );
    const decl = infer.findDeclarationInAst(&doc, "x") orelse return error.NoDecl;
    try testing.expect(decl.* == .declaration);
    try testing.expect(decl.declaration.is_const);
    try testing.expectEqualStrings("x", decl.declaration.name);
}

test "findDeclaration finds nested declaration inside function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@func main() {
        \\    $inner = 3;
        \\}
        \\
    );
    const decl = infer.findDeclarationInAst(&doc, "inner") orelse return error.NoDecl;
    try testing.expect(decl.* == .declaration);
    try testing.expectEqualStrings("inner", decl.declaration.name);
}

test "findDeclaration finds struct and its method" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@struct Counter {
        \\    count: int;
        \\    @func bump() {
        \\        $next = count + 1;
        \\    }
        \\}
        \\
    );
    const st = infer.findDeclarationInAst(&doc, "Counter") orelse return error.NoDecl;
    try testing.expect(st.* == .struct_decl);

    const next = infer.findDeclarationInAst(&doc, "next") orelse return error.NoDecl;
    try testing.expect(next.* == .declaration);
    try testing.expectEqualStrings("next", next.declaration.name);
}

test "findDeclaration returns null for unknown name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(), "@const $x = 1;\n");
    try testing.expectEqual(@as(?*ast.Node, null), infer.findDeclarationInAst(&doc, "nope"));
}

test "findDeclaration finds enum and error set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try parseDoc(arena.allocator(),
        \\@enum Color {
        \\    Red,
        \\}
        \\@error ParseFail {
        \\    BadInput,
        \\}
        \\
    );
    const en = infer.findDeclarationInAst(&doc, "Color") orelse return error.NoDecl;
    try testing.expect(en.* == .enum_decl);

    const err = infer.findDeclarationInAst(&doc, "ParseFail") orelse return error.NoDecl;
    try testing.expect(err.* == .error_decl);
}
