const Node = @import("root.zig").Node;
const Location = @import("root.zig").Location;

pub const LiteralKind = enum {
    number,
    string,
    boolean,
    hex,
    octal,
    binary,
    @"null",
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
    loc: Location,
};

pub const Member = struct {
    object: *Node,
    property: *Node,
    loc: Location,
};

pub const Index = struct {
    object: *Node,
    index: *Node,
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

pub const ErrorExpr = struct {
    message: *Node,
    loc: Location,
};

pub const StructFieldInit = struct {
    name: []const u8,
    value: *Node,
};

pub const StructInit = struct {
    name: []const u8,
    fields: []StructFieldInit,
    loc: Location,
};
