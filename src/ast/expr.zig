const Node = @import("root.zig").Node;
const Location = @import("root.zig").Location;

pub const LiteralKind = enum {
    number,
    string,
    boolean,
    hex,
    octal,
    binary,
    null,
};

pub const PrimaryKind = enum {
    identifier,
    register,
    literal,
    memory,
    immediate,
};

pub const Literal = struct {
    literal_type: LiteralKind,
    value: []const u8,
    type_name: ?[]const u8 = null,
    loc: Location,
};

pub const Primary = struct {
    kind: PrimaryKind,
    name: []const u8,
    loc: Location,
};

pub const Binary = struct {
    left: *Node,
    operator: []const u8,
    right: *Node,
    loc: Location,
};

pub const Unary = struct {
    operator: []const u8,
    arg: *Node,
    loc: Location,
};

pub const Assignment = struct {
    left: *Node,
    operator: []const u8,
    right: *Node,
    loc: Location,
};

pub const Call = struct {
    callee: *Node,
    args: []*Node,
    inline_asm: ?InlineAsm = null,
    loc: Location,
};

pub const AsmOutput = struct {
    name: []const u8,
    constraint: []const u8,
    /// Null for the single expression result (`-> Type`); otherwise the
    /// index of the destination place in `Call.args`.
    arg_index: ?usize = null,
    return_type: ?[]const u8 = null,
};

pub const AsmInput = struct {
    name: []const u8,
    constraint: []const u8,
    /// Index of the input expression in `Call.args`.
    arg_index: usize,
};

/// Parsed GNU-style extended assembly attached to an `@asm` call.
/// `Call.args[0]` is the declared result type; remaining arguments are the
/// expressions referenced by input/output `${...}` holes.
pub const InlineAsm = struct {
    template: []const u8,
    outputs: []AsmOutput,
    inputs: []AsmInput,
    clobbers: []const []const u8,
    is_volatile: bool = true,
};

pub const Member = struct {
    object: *Node,
    property: *Node,
    loc: Location,
};

pub const Index = struct {
    object: *Node,
    /// Start index. Null only for open-start slices `[..j]` / `[..]`.
    index: ?*Node = null,
    /// Exclusive end when `is_slice`. Null means open end (`[i..]` / `[..]`).
    end: ?*Node = null,
    /// True for `obj[a..b]`, `obj[a..]`, `obj[..b]`, `obj[..]` (vs plain `obj[i]`).
    is_slice: bool = false,
    type_annotation: ?*Node = null,
    loc: Location,
};

pub const ArrayLiteral = struct {
    elements: []*Node,
    loc: Location,
};

pub const TryExpr = struct {
    expression: *Node,
    loc: Location,
};

/// `.?` assertion-unwrap: panics (or returns error) if the value is null;
/// otherwise produces the unwrapped non-optional value.
pub const UnwrapExpr = struct {
    expression: *Node,
    loc: Location,
};

pub const ErrorExpr = struct {
    args: []*Node,
    loc: Location,
};

pub const StructFieldInit = struct {
    name: []const u8,
    value: *Node,
};

pub const StructInit = struct {
    /// `null` for an inferred object literal (`{ x: 1, y: 2 }`); the shape is
    /// inferred from the field values.
    type_expr: ?*Node,
    fields: []StructFieldInit,
    loc: Location,
};

pub const ComptimeExpr = struct {
    expr: *Node,
    loc: Location,
};
