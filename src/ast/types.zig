const Node = @import("root.zig").Node;
const Location = @import("root.zig").Location;

/// `[]T` or `[N]T` in a type position.
pub const ArrayType = struct {
    elem: *Node,
    /// null = unsized slice `[]T`.
    length: ?usize = null,
    loc: Location,
};

/// `T | U` in a type position.
pub const UnionType = struct {
    left: *Node,
    right: *Node,
    loc: Location,
};
