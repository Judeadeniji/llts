const Node = @import("root.zig").Node;
const Location = @import("root.zig").Location;

pub const Declaration = struct {
    name: []const u8,
    value: *Node,
    is_const: bool = false,
    is_public: bool = false,
    type_annotation: ?*Node = null,
    loc: Location,
};

pub const Param = struct {
    name: []const u8,
    type_annotation: ?*Node = null,
    is_rest: bool = false,
    loc: Location,
};

pub const Params = struct {
    params: []Param,
    is_variadic: bool = false,
    loc: Location,
};

pub const FunctionDecl = struct {
    name: []const u8,
    params: *Node,
    body: *Node,
    return_type: ?*Node = null,
    is_public: bool = false,
    loc: Location,
};

pub const Block = struct {
    statements: []*Node,
    label: ?[]const u8 = null,
    loc: Location,
};

pub const Return = struct {
    return_value: ?*Node,
    loc: Location,
};

pub const Defer = struct {
    body: *Node,
    is_errdefer: bool = false,
    loc: Location,
};

pub const Break = struct {
    label: ?[]const u8 = null,
    value: ?*Node = null,
    loc: Location,
};

pub const Continue = struct {
    label: ?[]const u8 = null,
    loc: Location,
};

pub const If = struct {
    condition: *Node,
    pipe_value: ?*Node,
    body: *Node,
    else_body: ?*Node = null,
    label: ?[]const u8 = null,
    loc: Location,
};

pub const Capture = struct {
    name: []const u8,
    by_ref: bool = false,
};

pub const For = struct {
    expr: *Node,
    captures: []Capture,
    label: ?[]const u8 = null,
    body: *Node,
    loc: Location,
};

pub const SwitchProng = struct {
    patterns: []*Node,
    is_else: bool = false,
    body: *Node,
    loc: Location,
};

pub const Switch = struct {
    condition: *Node,
    prongs: []SwitchProng,
    label: ?[]const u8 = null,
    loc: Location,
};


pub const Extern = struct {
    name: []const u8,
    is_public: bool = false,
    loc: Location,
};

pub const StructField = struct {
    name: []const u8,
    type_annotation: ?*Node,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []StructField,
    methods: []*Node,
    is_public: bool = false,
    loc: Location,
};

pub const EnumDecl = struct {
    name: []const u8,
    variants: []const []const u8,
    is_public: bool = false,
    loc: Location,
};
