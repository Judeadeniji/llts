const std = @import("std");
const helpers = @import("helpers.zig");

test "parser: variable and constant declarations" {
    const allocator = std.testing.allocator;
    const src =
        \\$x = 42;
        \\$y: int = 10;
        \\@const $MAX = 100;
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 4), doc.statements.len);
    try std.testing.expect(doc.statements[0].* == .declaration);
    try std.testing.expectEqualStrings("x", doc.statements[0].declaration.name);

    try std.testing.expect(doc.statements[1].* == .declaration);
    try std.testing.expectEqualStrings("y", doc.statements[1].declaration.name);
    try std.testing.expect(doc.statements[1].declaration.type_annotation != null);

    try std.testing.expect(doc.statements[2].* == .declaration);
    try std.testing.expectEqualStrings("MAX", doc.statements[2].declaration.name);
    try std.testing.expect(doc.statements[2].declaration.is_const);

    try std.testing.expect(doc.statements[3].* == .function_decl);
    try std.testing.expectEqualStrings("main", doc.statements[3].function_decl.name);
    try std.testing.expect(doc.statements[3].function_decl.is_public);
}

test "parser: struct declaration with fields and methods" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Vector2 {
        \\    x: int;
        \\    y: int;
        \\    @func lengthSquared(self: *Vector2): int {
        \\        return self.x * self.x + self.y * self.y;
        \\    }
        \\}
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expect(doc.statements.len >= 2);
    try std.testing.expect(doc.statements[0].* == .struct_decl);
    const s = &doc.statements[0].struct_decl;
    try std.testing.expectEqualStrings("Vector2", s.name);
    try std.testing.expectEqual(@as(usize, 2), s.fields.len);
    try std.testing.expectEqualStrings("x", s.fields[0].name);
    try std.testing.expectEqualStrings("y", s.fields[1].name);
    try std.testing.expectEqual(@as(usize, 1), s.methods.len);
    try std.testing.expectEqualStrings("lengthSquared", s.methods[0].function_decl.name);
}

test "parser: enum and error declarations" {
    const allocator = std.testing.allocator;
    const src =
        \\@enum Status { Pending, Active, Done }
        \\@error FileError { NotFound, AccessDenied }
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expect(doc.statements.len >= 3);
    try std.testing.expect(doc.statements[0].* == .enum_decl);
    try std.testing.expectEqualStrings("Status", doc.statements[0].enum_decl.name);
    try std.testing.expectEqual(@as(usize, 3), doc.statements[0].enum_decl.variants.len);

    try std.testing.expect(doc.statements[1].* == .error_decl);
    try std.testing.expectEqualStrings("FileError", doc.statements[1].error_decl.name);
}

test "parser: control flow (@if, @switch, @for)" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    @if (true) {
        \\        print("yes");
        \\    } @else {
        \\        print("no");
        \\    }
        \\    @switch (1) {
        \\        1 => { print(1); },
        \\        @else => { print(0); },
        \\    }
        \\    @for (0..10) |i| {
        \\        print(i);
        \\    }
        \\}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.statements.len);
    const body = doc.statements[0].function_decl.body.block.statements;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[0].* == .if_expr);
    try std.testing.expect(body[1].* == .switch_expr);
    try std.testing.expect(body[2].* == .for_expr);
}

test "parser: syntax error produces failure" {
    const allocator = std.testing.allocator;
    const invalid_src = "pub @func main( {"; // unclosed paren
    const res = helpers.parseSource(allocator, invalid_src);
    try std.testing.expectError(error.ParseFailed, res);
}
