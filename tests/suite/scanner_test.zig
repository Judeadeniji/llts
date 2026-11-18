const std = @import("std");
const helpers = @import("helpers.zig");

test "scanner: numbers and bases" {
    const allocator = std.testing.allocator;
    const src = "42 0x2A 0b101010 0o52 3.14159";
    var res = try helpers.scanSource(allocator, src, null);
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
    var res = try helpers.scanSource(allocator, src, null);
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
    var res = try helpers.scanSource(allocator, src, null);
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
    var res = try helpers.scanSource(allocator, src, null);
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

test "scanner: all escape characters" {
    const allocator = std.testing.allocator;
    const src =
        \\"\\a: \a"
        \\"\\b: \b"
        \\"\\e: \e"
        \\"\\f: \f"
        \\"\\n: \n"
        \\"\\r: \r"
        \\"\\t: \t"
        \\"\\v: \v"
        \\"\\\\: \\"
        \\"\\\": \""
        \\"\\\': \'"
        \\"\\0: \0"
        \\"\\NNN: \007 \040 \077 \101 \377"
        \\"\\xNN: \x07 \x1b \x41 \xff"
        \\"\\uNNNN: \u0041 \u00e9 \u4e16"
        \\"\\UNNNNNNNN: \U00000041 \U000000E9 \U0001F600"
    ;
    var res = try helpers.scanSource(allocator, src, null);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expectEqual(@as(usize, 17), tokens.len); // 16 strings + EOF

    // \a - bell (ASCII 7)
    try std.testing.expectEqualStrings("\\a: \x07", tokens[0].value);
    // \b - backspace (ASCII 8)
    try std.testing.expectEqualStrings("\\b: \x08", tokens[1].value);
    // \e - escape (ASCII 27 / 0x1B)
    try std.testing.expectEqualStrings("\\e: \x1b", tokens[2].value);
    // \f - form feed (ASCII 12 / 0x0C)
    try std.testing.expectEqualStrings("\\f: \x0c", tokens[3].value);
    // \n - newline (ASCII 10)
    try std.testing.expectEqualStrings("\\n: \n", tokens[4].value);
    // \r - carriage return (ASCII 13)
    try std.testing.expectEqualStrings("\\r: \r", tokens[5].value);
    // \t - tab (ASCII 9)
    try std.testing.expectEqualStrings("\\t: \t", tokens[6].value);
    // \v - vertical tab (ASCII 11 / 0x0B)
    try std.testing.expectEqualStrings("\\v: \x0b", tokens[7].value);
    // \\ - backslash
    try std.testing.expectEqualStrings("\\\\: \\", tokens[8].value);
    // \" - double quote
    try std.testing.expectEqualStrings("\\\": \"", tokens[9].value);
    // \' - single quote
    try std.testing.expectEqualStrings("\\\': '", tokens[10].value);
    // \0 - null byte
    try std.testing.expectEqualStrings("\\0: \x00", tokens[11].value);
    // \NNN - octal (3 digits)
    try std.testing.expectEqualStrings("\\NNN: \x07 \x20 \x3f A \xff", tokens[12].value);
    // \xNN - hexadecimal (2 digits)
    try std.testing.expectEqualStrings("\\xNN: \x07 \x1b A \xff", tokens[13].value);
    // \uNNNN - Unicode 16-bit UTF-8 encoded (4 digits)
    try std.testing.expectEqualStrings("\\uNNNN: A é 世", tokens[14].value);
    // \UNNNNNNNN - Unicode 32-bit UTF-8 encoded (8 digits)
    try std.testing.expectEqualStrings("\\UNNNNNNNN: A é 😀", tokens[15].value);
}

test "scanner: single-quoted string with escapes" {
    const allocator = std.testing.allocator;
    const src = "'line1\\nline2\\t\\\'single\\\' \\x41 \\u0042 \\103'";
    var res = try helpers.scanSource(allocator, src, null);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(helpers.scanner.TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("line1\nline2\t'single' A B C", tokens[0].value);
}

test "scanner: escape error cases" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { src: []const u8, needle: []const u8 }{
        .{ .src = "\"\\xG1\"", .needle = "Invalid hex escape sequence" },
        .{ .src = "\"\\x4\"", .needle = "Invalid hex escape sequence" },
        .{ .src = "\"\\u041\"", .needle = "Invalid Unicode escape sequence" },
        .{ .src = "\"\\uD800\"", .needle = "surrogate halves are not permitted" },
        .{ .src = "\"\\U00110000\"", .needle = "Unicode code point out of range" },
        .{ .src = "\"\\400\"", .needle = "out of range" },
        .{ .src = "\"\\18\"", .needle = "Invalid octal escape sequence" },
    };

    for (cases) |c| {
        var coll = helpers.collector.Collector.init(allocator, 10);
        defer coll.deinit();
        helpers.collector.setActive(&coll);
        defer helpers.collector.clearActive();

        var res = try helpers.scanSource(allocator, c.src, null);
        helpers.scanner.deinitScanResult(&res);

        try std.testing.expect(coll.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, coll.items.items[0].message, c.needle) != null);
    }
}

test "scanner: operators and delimiters" {
    const allocator = std.testing.allocator;
    const src = "+ - * / % +% -% *% & | ^ ~ << >> == != < <= > >= && || ! ? .. ... -> =>";
    var res = try helpers.scanSource(allocator, src, null);
    defer helpers.scanner.deinitScanResult(&res);

    const tokens = res.tokens.items;
    try std.testing.expect(tokens.len > 20);
    try std.testing.expectEqual(helpers.scanner.TokenType.eof, tokens[tokens.len - 1].type);
}
