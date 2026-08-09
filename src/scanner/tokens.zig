pub const TokenType = enum {
    keyword,
    identifier,
    v_register,
    compiler_keyword,
    string,
    number,
    hex,
    octal,
    binary,
    boolean,
    delimiter,
    type_decl,
    bin_op,
    unary_op,
    assign_op,
    eof,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    line: u32,
    column: u32,
};

pub const ScanResult = struct {
    tokens: @import("std").ArrayList(Token),
    allocator: @import("std").mem.Allocator,
};
