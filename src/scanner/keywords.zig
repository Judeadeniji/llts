const std = @import("std");

const compiler_map = std.StaticStringMap(void).initComptime(.{
    .{ "import", {} }, .{ "const", {} }, .{ "func", {} }, .{ "for", {} }, .{ "if", {} }, .{ "else", {} }, 
    .{ "switch", {} }, .{ "struct", {} }, .{ "enum", {} }, .{ "isError", {} }, .{ "typeOf", {} }, .{ "sizeOf", {} }, .{ "extern", {} }, .{ "new", {} }
});

const keyword_map = std.StaticStringMap(void).initComptime(.{
    .{ "true", {} }, .{ "false", {} }, .{ "return", {} }, .{ "pub", {} }, .{ "break", {} }, 
    .{ "continue", {} }, .{ "defer", {} }, .{ "errdefer", {} }, .{ "error", {} }, .{ "null", {} }
});

pub fn isCompilerSymbol(w: []const u8) bool {
    return compiler_map.has(w);
}

pub fn isKeyword(w: []const u8) bool {
    return keyword_map.has(w);
}

pub fn isDelimiter(c: u8) bool {
    return switch (c) {
        ',', ';', ':', '(', ')', '{', '}', '[', ']', '.', '?' => true,
        else => false,
    };
}
