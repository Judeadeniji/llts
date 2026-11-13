const std = @import("std");
const helpers = @import("helpers.zig");

test "scanner: numbers and bases" {
    const allocator = std.testing.allocator;
    const src = "42 0x2A 0b101010 0o52 3.14159";
    var res = try helpers.scanSource(allocator, src);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expectEqual(@as(usize, 6), tokens.len); // 5 tokens + EOF

    try std.testing.expectEqual(helpers.scanner.TokenType.number, tokens[0].type);
    try std.testing.expectEqualStrings("42", tokens[0].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.hex, tokens[1].type);
    try std.testing.expectEqualStrings("0x2A", tokens[1].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.binary, tokens[2].type);
    try std.testing.expectEqualStrings("0b101010", tokens[2].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.octal, tokens[3].type);
    try std.testing.expectEqualStrings("0o52", tokens[3].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.number, tokens[4].type);
    try std.testing.expectEqualStrings("3.14159", tokens[4].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.eof, tokens[5].type);
}

test "scanner: identifiers and registers" {
    const allocator = std.testing.allocator;
    const src = "foo _bar $reg $0 $my_val";
    var res = try helpers.scanSource(allocator, src);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expectEqual(@as(usize, 6), tokens.len);

    try std.testing.expectEqual(helpers.scanner.TokenType.identifier, tokens[0].type);
    try std.testing.expectEqualStrings("foo", tokens[0].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.identifier, tokens[1].type);
    try std.testing.expectEqualStrings("_bar", tokens[1].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.v_register, tokens[2].type);
    try std.testing.expectEqualStrings("reg", tokens[2].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.v_register, tokens[3].type);
    try std.testing.expectEqualStrings("0", tokens[3].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.v_register, tokens[4].type);
    try std.testing.expectEqualStrings("my_val", tokens[4].value);
}

test "scanner: compiler keywords vs language keywords" {
    const allocator = std.testing.allocator;
    const src = "@func @struct @enum @type @if @switch @for pub return defer errdefer";
    var res = try helpers.scanSource(allocator, src);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expect(tokens.len >= 11);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[0].type);
    try std.testing.expectEqualStrings("func", tokens[0].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[1].type);
    try std.testing.expectEqualStrings("struct", tokens[1].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[2].type);
    try std.testing.expectEqualStrings("enum", tokens[2].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[3].type);
    try std.testing.expectEqualStrings("type", tokens[3].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[4].type);
    try std.testing.expectEqualStrings("if", tokens[4].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[5].type);
    try std.testing.expectEqualStrings("switch", tokens[5].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.compiler_keyword, tokens[6].type);
    try std.testing.expectEqualStrings("for", tokens[6].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.keyword, tokens[7].type);
    try std.testing.expectEqualStrings("pub", tokens[7].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.keyword, tokens[8].type);
    try std.testing.expectEqualStrings("return", tokens[8].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.keyword, tokens[9].type);
    try std.testing.expectEqualStrings("defer", tokens[9].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.keyword, tokens[10].type);
    try std.testing.expectEqualStrings("errdefer", tokens[10].value);
}

test "scanner: strings and escape characters" {
    const allocator = std.testing.allocator;
    const src = "\"hello\\nworld\" \"tab\\tseparated\" \"escaped\\\"quote\"";
    var res = try helpers.scanSource(allocator, src);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expectEqual(@as(usize, 4), tokens.len); // 3 strings + EOF

    try std.testing.expectEqual(helpers.scanner.TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\nworld", tokens[0].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.string, tokens[1].type);
    try std.testing.expectEqualStrings("tab\tseparated", tokens[1].value);

    try std.testing.expectEqual(helpers.scanner.TokenType.string, tokens[2].type);
    try std.testing.expectEqualStrings("escaped\"quote", tokens[2].value);
}

test "scanner: operators and delimiters" {
    const allocator = std.testing.allocator;
    const src = "+ - * / % +% -% *% & | ^ ~ << >> == != < <= > >= && || ! ? .. ... -> =>";
    var res = try helpers.scanSource(allocator, src);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expect(tokens.len > 20);
    try std.testing.expectEqual(helpers.scanner.TokenType.eof, tokens[tokens.len - 1].type);
}
