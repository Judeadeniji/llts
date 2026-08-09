const std = @import("std");

pub const compiler_symbols = [_][]const u8{
    "import", "const", "func", "for", "if", "else", "struct", "isError", "typeOf", "extern",
};

pub const keywords = [_][]const u8{
    "true", "false", "return", "pub", "break", "continue", "defer", "error", "null",
};

pub fn isCompilerSymbol(w: []const u8) bool {
    for (compiler_symbols) |s| {
        if (std.mem.eql(u8, s, w)) return true;
    }
    return false;
}

pub fn isKeyword(w: []const u8) bool {
    for (keywords) |s| {
        if (std.mem.eql(u8, s, w)) return true;
    }
    return false;
}

pub fn isDelimiter(c: u8) bool {
    return switch (c) {
        ',', ';', ':', '(', ')', '{', '}', '[', ']', '.', '|', '?' => true,
        else => false,
    };
}
