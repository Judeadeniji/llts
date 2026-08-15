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
    /// Index into Chunk.sources for this function's originating file.
    source_index: u16 = 0,
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

/// Handle for a packed value array living in `VMState.bytes`.
pub const ArrayRef = struct {
    offset: u32,
    count: u32,
};

/// Tagged runtime value — numeric tags match Zig-like widths end-to-end.
pub const Value = union(enum) {
    null,
    /// 1-bit unsigned (`bool` / `boolean` alias `u1`).
    u1: u1,
    i8: i8,
    i16: i16,
    i32: i32,
    i64: i64,
    u8: u8,
    u16: u16,
    u32: u32,
    u64: u64,
    f32: f32,
    f64: f64,
    /// Pointer into the Value-slot heap (errors, arena control).
    ptr: i32,
    native: *const NativeFunction,
    function: LltsFunction,
    /// Interned name index into the chunk string table (for globals/properties).
    name: u32,
    /// String view pointing into the VM's unified packed byte heap (`VMState.bytes`).
    slice: struct { offset: u32, len: u32 },
    /// Packed mutable bytes in `VMState.bytes` (structs, `[]byte`).
    bytes: struct { offset: u32, len: u32 },
    /// Packed value array in `VMState.bytes`: `count` elements of `@sizeOf(Value)` at `offset`.
    array: ArrayRef,
    /// Module object from OP_GET_MODULE.
    module: *ModuleObject,
    /// Growable List (std/list).
    list: *ListObject,
    /// Growable Map (std/map).
    map: *MapObject,
    /// Byte Buffer (std/buffer).
    buffer: *BufferObject,

    pub fn fromBool(b: bool) Value {
        return .{ .u1 = @intFromBool(b) };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .u1 => |n| n != 0,
            .i8 => |n| n != 0,
            .i16 => |n| n != 0,
            .i32 => |n| n != 0,
            .i64 => |n| n != 0,
            .u8 => |n| n != 0,
            .u16 => |n| n != 0,
            .u32 => |n| n != 0,
            .u64 => |n| n != 0,
            .f32 => |n| n != 0,
            .f64 => |n| n != 0,
            .ptr => true,
            .slice => |s| s.len > 0,
            .bytes => |b| b.len > 0,
            .array => |a| a.count > 0,
            .native, .function, .name, .module, .list, .map, .buffer => true,
        };
    }
};

test "value truthiness" {
    try std.testing.expect(!(Value{ .null = {} }).isTruthy());
    try std.testing.expect(Value.fromBool(true).isTruthy());
    try std.testing.expect(!Value.fromBool(false).isTruthy());
    try std.testing.expect(!(Value{ .i64 = 0 }).isTruthy());
}
