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

pub const Params = struct {
    params: []*Node,
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
    loc: Location,
};

pub const Return = struct {
    return_value: ?*Node,
    loc: Location,
};

pub const Defer = struct {
    body: *Node,
    loc: Location,
};

pub const Break = struct {
    label: ?[]const u8 = null,
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
    loc: Location,
};

pub const Capture = struct {
    name: []const u8,
    by_ref: bool = false,
};

pub const ForKind = enum { condition, range, iterable };

pub const For = struct {
    kind: ForKind,
    condition: ?*Node = null,
    range_start: ?*Node = null,
    range_end: ?*Node = null,
    iterable: ?*Node = null,
    captures: []Capture,
    label: ?[]const u8 = null,
    body: *Node,
    loc: Location,
};

pub const Import = struct {
    import_path: []const u8,
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
