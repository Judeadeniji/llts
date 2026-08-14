const std = @import("std");
const chunk_mod = @import("../bytecode/chunk.zig");
const value = @import("../bytecode/value.zig");

pub const Value = value.Value;
pub const Chunk = chunk_mod.Chunk;
pub const ModuleObject = value.ModuleObject;
pub const ListObject = value.ListObject;
pub const MapObject = value.MapObject;

pub const MEMORY_SIZE: usize = 1024 * 1024;
pub const BYTE_MEMORY_SIZE: usize = 1024 * 1024;
pub const HEAP_START: i32 = 1024;
pub const BYTE_HEAP_START: i32 = 0;
pub const ERROR_TAG: i32 = 0xE2202;
pub const MAX_FRAMES: usize = 256;

pub const CallFrame = struct {
    return_ip: usize = 0,
    base_slot: usize = 0,
    arg_count: u8 = 0,
    const_slots: std.AutoHashMap(u8, void),
    func_name: []const u8 = "<anonymous>",
    /// Borrowed path from chunk.sources.
    file: []const u8 = "",
    line: u32 = 1,
    column: u32 = 1,
    source_index: u16 = 0,
    /// Heap bump at call entry. On return, `heap_ptr` rewinds here so
    /// frame-local implicit allocs (bare `Foo{}` / `[…]`) die with the frame.
    /// Immortal allocs raise this watermark so arenas / `@new` targets survive.
    heap_watermark: i32 = HEAP_START,

    pub fn init(allocator: std.mem.Allocator) CallFrame {
        return .{
            .const_slots = std.AutoHashMap(u8, void).init(allocator),
        };
    }

    pub fn deinit(self: *CallFrame) void {
        self.const_slots.deinit();
    }
};

pub const VMState = struct {
    allocator: std.mem.Allocator,
    globals: std.StringHashMap(Value),
    stack: std.ArrayList(Value) = .empty,
    frames: std.ArrayList(CallFrame) = .empty,
    memory: []Value,
    heap_ptr: i32 = HEAP_START,
    immortal_ptr: i32 = @intCast(MEMORY_SIZE),
    free_chunks: i32 = 0,
    /// Packed byte heap (`[]byte` / `[N]byte`). One byte per element, not one Value.
    bytes: []u8,
    byte_ptr: i32 = BYTE_HEAP_START,
    byte_immortal_ptr: i32 = @intCast(BYTE_MEMORY_SIZE),
    free_byte_chunks: i32 = 0,
    chunk: *Chunk,
    current_line: u32 = 1,
    current_column: u32 = 1,
    current_source_index: u16 = 0,
    /// Owned module instances created by OP_GET_MODULE.
    modules: std.ArrayList(*ModuleObject) = .empty,
    lists: std.ArrayList(*value.ListObject) = .empty,
    maps: std.ArrayList(*value.MapObject) = .empty,
    buffers: std.ArrayList(*value.BufferObject) = .empty,
    /// Cache: constant string index → heap data pointer, avoids re-allocating the same literal.
    string_cache: std.AutoHashMap(u32, i32),
    /// Zero-alloc string arena (appended to, never freed during execution).
    string_bytes: std.ArrayList(u8) = .empty,
    /// Path of the running script (borrowed; used by os.args as argv[0]).
    script_path: []const u8 = "",
    /// Extra argv after the script path (borrowed; used by os.args as argv[1..]).
    script_args: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) !VMState {
        const memory = try allocator.alloc(Value, MEMORY_SIZE);
        @memset(memory, .null);
        const bytes = try allocator.alloc(u8, BYTE_MEMORY_SIZE);
        @memset(bytes, 0);
        var state: VMState = .{
            .allocator = allocator,
            .globals = std.StringHashMap(Value).init(allocator),
            .string_cache = std.AutoHashMap(u32, i32).init(allocator),
            .memory = memory,
            .bytes = bytes,
            .chunk = chunk,
        };
        var frame = CallFrame.init(allocator);
        frame.func_name = "<anonymous>";
        frame.file = if (chunk.file.len > 0) chunk.file else "<anonymous>";
        frame.source_index = 0;
        // Script frame lives until process end — watermark tracks immortal growth.
        frame.heap_watermark = HEAP_START;
        try state.frames.append(allocator, frame);
        try state.stack.ensureTotalCapacity(allocator, 1024);
        return state;
    }

    pub fn sourceForFile(self: *const VMState, path: []const u8) []const u8 {
        for (self.chunk.sources.items) |s| {
            if (std.mem.eql(u8, s.path, path)) return s.text;
        }
        return self.chunk.source;
    }

    pub fn deinit(self: *VMState) void {
        for (self.frames.items) |*f| f.deinit();
        self.frames.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.globals.deinit();
        for (self.modules.items) |mod| {
            mod.deinit(self.allocator);
            self.allocator.destroy(mod);
        }
        self.modules.deinit(self.allocator);
        for (self.lists.items) |lst| {
            lst.deinit(self.allocator);
            self.allocator.destroy(lst);
        }
        self.lists.deinit(self.allocator);
        for (self.maps.items) |mp| {
            mp.deinit(self.allocator);
            self.allocator.destroy(mp);
        }
        self.maps.deinit(self.allocator);
        for (self.buffers.items) |buf| {
            buf.deinit(self.allocator);
            self.allocator.destroy(buf);
        }
        self.buffers.deinit(self.allocator);
        self.string_cache.deinit();
        self.string_bytes.deinit(self.allocator);
        self.allocator.free(self.memory);
        self.allocator.free(self.bytes);
    }

    /// Frame-local bump. Rewound when the current call returns (see `doReturn`).
    pub fn allocSlots(self: *VMState, count: i32) !i32 {
        const ptr = self.heap_ptr;
        if (ptr + count > self.immortal_ptr) return error.OutOfMemory;
        self.heap_ptr += count;
        return ptr;
    }

    /// Process-/pass-lifetime bump (arenas, `error(…)`, values meant to escape a frame).
    /// Allocated downwards from the end of the heap to avoid leaking frame-local variables.
    pub fn allocImmortal(self: *VMState, count: i32) !i32 {
        if (self.immortal_ptr - count < self.heap_ptr) return error.OutOfMemory;
        self.immortal_ptr -= count;
        return self.immortal_ptr;
    }

    pub fn isValidHeapPtr(self: *const VMState, ptr: i64) bool {
        if (ptr < HEAP_START) return false;
        if (ptr >= @as(i64, @intCast(MEMORY_SIZE))) return false;
        const p: i32 = @intCast(ptr);
        if (p >= self.heap_ptr and p < self.immortal_ptr) return false;
        return true;
    }

    /// Packed bytes for `@new(a, []byte, n)` / `[N]byte`. Bump from the immortal end
    /// (same region as arena chunks) so frame rewind of `heap_ptr` cannot clobber them.
    pub fn allocImmortalBytes(self: *VMState, count: i32) !i32 {
        if (count < 0) return error.OutOfMemory;
        if (self.byte_immortal_ptr - count < self.byte_ptr) return error.OutOfMemory;
        self.byte_immortal_ptr -= count;
        const ptr = self.byte_immortal_ptr;
        @memset(self.bytes[@intCast(ptr)..][0..@intCast(count)], 0);
        return ptr;
    }

    pub fn packedBytes(self: *VMState, offset: u32, len: u32) []u8 {
        return self.bytes[offset..][0..len];
    }

    pub fn allocModule(self: *VMState, name: []const u8) !*ModuleObject {
        const mod = try self.allocator.create(ModuleObject);
        mod.* = .{
            .name = name,
            .props = std.StringHashMap(Value).init(self.allocator),
        };
        try self.modules.append(self.allocator, mod);
        return mod;
    }

    pub fn allocList(self: *VMState) !*ListObject {
        const lst = try self.allocator.create(ListObject);
        lst.* = .{ .items = .empty };
        try self.lists.append(self.allocator, lst);
        return lst;
    }

    pub fn allocMap(self: *VMState) !*value.MapObject {
        const mp = try self.allocator.create(value.MapObject);
        mp.* = .{ .entries = std.StringHashMap(Value).init(self.allocator) };
        try self.maps.append(self.allocator, mp);
        return mp;
    }

    pub fn allocBuffer(self: *VMState) !*value.BufferObject {
        const buf = try self.allocator.create(value.BufferObject);
        buf.* = .{ .bytes = .empty };
        try self.buffers.append(self.allocator, buf);
        return buf;
    }
};
