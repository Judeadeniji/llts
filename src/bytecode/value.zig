const std = @import("std");

pub const NativeFn = *const fn (vm: *anyopaque, args: []Value) anyerror!Value;

pub const NativeFunction = struct {
    name: []const u8,
    func: NativeFn,
    arity: i32, // -1 = variadic
};

pub const LltsFunction = struct {
    name: []const u8,
    address: u32,
    arity: u8,
    is_variadic: bool = false,
};

/// Runtime module instance from OP_GET_MODULE (owns dynamic properties).
pub const ModuleObject = struct {
    name: []const u8,
    props: std.StringHashMap(Value),

    pub fn deinit(self: *ModuleObject, allocator: std.mem.Allocator) void {
        var it = self.props.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.props.deinit();
    }
};

/// Tagged runtime value. Heap objects (arrays, strings, errors, structs) use `.ptr`.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i32,
    float: f64,
    /// Pointer into the i32 heap (arrays, strings, errors, structs).
    ptr: i32,
    native: *const NativeFunction,
    function: LltsFunction,
    /// Interned name index into the chunk string table (for globals/properties).
    name: u32,
    /// Module object from OP_GET_MODULE.
    module: *ModuleObject,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |b| b,
            .int => |n| n != 0,
            .float => |n| n != 0,
            .ptr => true,
            .native, .function, .name, .module => true,
        };
    }
};

test "value truthiness" {
    try std.testing.expect(!(Value{ .null = {} }).isTruthy());
    try std.testing.expect((Value{ .bool = true }).isTruthy());
    try std.testing.expect(!(Value{ .bool = false }).isTruthy());
    try std.testing.expect(!(Value{ .int = 0 }).isTruthy());
}
