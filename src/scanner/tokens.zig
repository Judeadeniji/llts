pub const TokenType = enum {
    keyword,
    identifier,
    v_register,
    compiler_keyword,
    string,
    /// Fenced multiline template (` ``` ` … ` ``` `). `value` is the raw body
    /// (escapes uncooked). `template_parts` splits text / `${…}` holes.
    template,
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

/// One slice of a fenced template body: plain text or a single-expression hole.
pub const TemplatePart = struct {
    is_hole: bool,
    /// Text part: raw body slice (escapes still raw). Hole: source between
    /// `${` and the matching `}` (no surrounding braces).
    value: []const u8,
    line: u32,
    column: u32,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    line: u32,
    column: u32,
    /// Owned by `ScanResult` for `.template` tokens; null otherwise.
    template_parts: ?[]TemplatePart = null,
};

pub const ScanResult = struct {
    tokens: @import("std").ArrayList(Token),
    allocator: @import("std").mem.Allocator,
};
