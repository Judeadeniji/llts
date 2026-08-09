const std = @import("std");
const parser = @import("parser/root.zig");
const scanner = @import("scanner/root.zig");

test "assign member index pipe structinit for" {
    const src =
        \\$x = a.b[0] |> f;
        \\x += 1;
        \\$s = Point{ x: 1, y: 2 };
        \\@for (items) |it| {}
        \\@for (i < 10) {}
        \\
    ;
    var scan_result = try scanner.scan(std.testing.allocator, src, "t.lls");
    defer scanner.deinitScanResult(&scan_result);
    var doc = try parser.parse(std.testing.allocator, scan_result.tokens.items, "t.lls", src);
    defer doc.deinit();
    try std.testing.expect(doc.statements.len == 5);
    try std.testing.expect(doc.statements[2].declaration.value.* == .struct_init);
    try std.testing.expect(doc.statements[3].for_expr.kind == .iterable);
    try std.testing.expect(doc.statements[4].for_expr.kind == .condition);
}

test "union type and fixed array" {
    const src = "$a: [2]int | error = 1;\n";
    var scan_result = try scanner.scan(std.testing.allocator, src, "t.lls");
    defer scanner.deinitScanResult(&scan_result);
    var doc = try parser.parse(std.testing.allocator, scan_result.tokens.items, "t.lls", src);
    defer doc.deinit();
    try std.testing.expect(doc.statements[0].declaration.type_annotation.?.* == .union_type);
}
