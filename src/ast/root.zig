const std = @import("std");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");
const types = @import("types.zig");

pub const Location = struct {
    line: u32 = 0,
    column: u32 = 0,
};

pub const LiteralKind = expr.LiteralKind;
pub const PrimaryKind = expr.PrimaryKind;
pub const Literal = expr.Literal;
pub const Primary = expr.Primary;
pub const Binary = expr.Binary;
pub const Unary = expr.Unary;
pub const Assignment = expr.Assignment;
pub const Call = expr.Call;
pub const Member = expr.Member;
pub const Index = expr.Index;
pub const ArrayLiteral = expr.ArrayLiteral;
pub const TryExpr = expr.TryExpr;
pub const ErrorExpr = expr.ErrorExpr;
pub const StructFieldInit = expr.StructFieldInit;
pub const StructInit = expr.StructInit;

pub const Declaration = stmt.Declaration;
pub const Params = stmt.Params;
pub const FunctionDecl = stmt.FunctionDecl;
pub const Block = stmt.Block;
pub const Return = stmt.Return;
pub const Defer = stmt.Defer;
pub const Break = stmt.Break;
pub const Continue = stmt.Continue;
pub const If = stmt.If;
pub const Capture = stmt.Capture;
pub const ForKind = stmt.ForKind;
pub const For = stmt.For;
pub const Import = stmt.Import;
pub const Extern = stmt.Extern;
pub const StructField = stmt.StructField;
pub const StructDecl = stmt.StructDecl;

pub const ArrayType = types.ArrayType;
pub const UnionType = types.UnionType;

pub const Node = union(enum) {
    declaration: Declaration,
    literal: Literal,
    primary: Primary,
    binary: Binary,
    unary: Unary,
    assignment: Assignment,
    call: Call,
    member: Member,
    index: Index,
    array_literal: ArrayLiteral,
    function_decl: FunctionDecl,
    params: Params,
    block: Block,
    return_expr: Return,
    if_expr: If,
    for_expr: For,
    break_expr: Break,
    continue_expr: Continue,
    defer_stmt: Defer,
    import: Import,
    struct_decl: StructDecl,
    struct_init: StructInit,
    try_expr: TryExpr,
    error_expr: ErrorExpr,
    extern_decl: Extern,
    array_type: ArrayType,
    union_type: UnionType,

    pub fn loc(self: *const Node) Location {
        return switch (self.*) {
            inline else => |payload| payload.loc,
        };
    }
};

/// Parsed document; owns an arena that frees all nodes on `deinit`.
pub const Document = struct {
    path: []const u8,
    source: []const u8,
    statements: []*Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

// Re-export aliases matching TS names where helpful.
pub const DocumentBody = Document;
pub const Try = TryExpr;
pub const Error = ErrorExpr;
