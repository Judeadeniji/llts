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

pub const MapObject = struct {
    entries: std.StringHashMap(Value),

    pub fn deinit(self: *MapObject, allocator: std.mem.Allocator) void {
        var it = self.entries.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.entries.deinit();
    }
};

pub const ListObject = struct {
    items: std.ArrayList(Value),

    pub fn deinit(self: *ListObject, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

pub const BufferObject = struct {
    bytes: std.ArrayList(u8),

    pub fn deinit(self: *BufferObject, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
};

/// Tagged runtime value. Heap objects (arrays, strings, errors, structs) use `.ptr`.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    /// Pointer into the i32 heap (arrays, strings, errors, structs).
    ptr: i32,
    native: *const NativeFunction,
    function: LltsFunction,
    /// Interned name index into the chunk string table (for globals/properties).
    name: u32,
    /// String view pointing into the VM's global string_bytes buffer.
    slice: struct { offset: u32, len: u32 },
    /// Module object from OP_GET_MODULE.
    module: *ModuleObject,
    /// Growable List (std/list).
    list: *ListObject,
    /// Growable Map (std/map).
    map: *MapObject,
    /// Byte Buffer (std/buffer).
    buffer: *BufferObject,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |b| b,
            .int => |n| n != 0,
            .float => |n| n != 0,
            .ptr => true,
            .slice => |s| s.len > 0,
            .native, .function, .name, .module, .list, .map, .buffer => true,
        };
    }
};

test "value truthiness" {
    try std.testing.expect(!(Value{ .null = {} }).isTruthy());
    try std.testing.expect((Value{ .bool = true }).isTruthy());
    try std.testing.expect(!(Value{ .bool = false }).isTruthy());
    try std.testing.expect(!(Value{ .int = 0 }).isTruthy());
}
