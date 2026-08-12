const std = @import("std");
const chunk_mod = @import("../bytecode/chunk.zig");
const value = @import("../bytecode/value.zig");

pub const Value = value.Value;
pub const Chunk = chunk_mod.Chunk;
pub const ModuleObject = value.ModuleObject;

pub const MEMORY_SIZE: usize = 1024 * 1024;
pub const HEAP_START: i32 = 1024;
pub const ERROR_TAG: i32 = 0xE2202;
pub const MAX_FRAMES: usize = 256;

pub const CallFrame = struct {
    return_ip: usize = 0,
    base_slot: usize = 0,
    arg_count: u8 = 0,
    const_slots: std.AutoHashMap(u8, void),
    func_name: []const u8 = "<script>",
    line: u32 = 1,
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
    chunk: *Chunk,
    current_line: u32 = 1,
    /// Owned module instances created by OP_GET_MODULE.
    modules: std.ArrayList(*ModuleObject) = .empty,
    /// Cache: constant string index → heap data pointer, avoids re-allocating the same literal.
    string_cache: std.AutoHashMap(u32, i32),
    /// Zero-alloc string arena (appended to, never freed during execution).
    string_bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) !VMState {
        const memory = try allocator.alloc(Value, MEMORY_SIZE);
        @memset(memory, .null);
        var state: VMState = .{
            .allocator = allocator,
            .globals = std.StringHashMap(Value).init(allocator),
            .string_cache = std.AutoHashMap(u32, i32).init(allocator),
            .memory = memory,
            .chunk = chunk,
        };
        var frame = CallFrame.init(allocator);
        frame.func_name = "<script>";
        // Script frame lives until process end — watermark tracks immortal growth.
        frame.heap_watermark = HEAP_START;
        try state.frames.append(allocator, frame);
        try state.stack.ensureTotalCapacity(allocator, 1024);
        return state;
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
        self.string_cache.deinit();
        self.string_bytes.deinit(self.allocator);
        self.allocator.free(self.memory);
    }

    /// Frame-local bump. Rewound when the current call returns (see `doReturn`).
    pub fn allocSlots(self: *VMState, count: i32) !i32 {
        const ptr = self.heap_ptr;
        if (ptr + count >= @as(i32, @intCast(self.memory.len))) return error.OutOfMemory;
        self.heap_ptr += count;
        return ptr;
    }

    /// Process-/pass-lifetime bump (arenas, `error(…)`, values meant to escape a frame).
    /// Raises every frame watermark so a later return cannot rewind past this block.
    pub fn allocImmortal(self: *VMState, count: i32) !i32 {
        const ptr = try self.allocSlots(count);
        for (self.frames.items) |*f| {
            if (f.heap_watermark < self.heap_ptr) f.heap_watermark = self.heap_ptr;
        }
        return ptr;
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
};
