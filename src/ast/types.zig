const Node = @import("root.zig").Node;
const Location = @import("root.zig").Location;

/// `[]T` or `[N]T` in a type position.
pub const ArrayType = struct {
    elem: *Node,
    /// null = unsized slice `[]T`.
    length_text: ?[]const u8 = null,
    loc: Location,
};

/// `[T, U, …]` fixed heterogeneous product in a type position.
pub const TupleType = struct {
    elems: []*Node,
    loc: Location,
};

/// `T | U` in a type position.
pub const UnionType = struct {
    left: *Node,
    right: *Node,
    loc: Location,
};

/// `*T` in a type position (pointer to pointee).
pub const PointerType = struct {
    elem: *Node,
    loc: Location,
};

/// `@func(T, U): R` in a type position (types only — no param names).
pub const FuncType = struct {
    params: []*Node,
    return_type: ?*Node = null,
    is_variadic: bool = false,
    loc: Location,
};
