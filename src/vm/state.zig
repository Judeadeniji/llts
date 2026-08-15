const std = @import("std");
const chunk_mod = @import("../bytecode/chunk.zig");
const value = @import("../bytecode/value.zig");

pub const Value = value.Value;
pub const Chunk = chunk_mod.Chunk;
pub const ModuleObject = value.ModuleObject;
pub const ListObject = value.ListObject;
pub const MapObject = value.MapObject;

pub const HEAP_START: i32 = 1024;
/// Immortal (arena / `@new` / errors) live in a separate growable list.
/// Encoded as `IMMORTAL_BASE + index` so they never collide with frame ptrs.
pub const IMMORTAL_BASE: i32 = 1 << 30;
pub const ERROR_TAG: i32 = 0xE2202;
pub const MAX_FRAMES: usize = 256;
pub const STACK_MAX: usize = 1024;

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
    /// Immortal allocs live in a separate growable list and are not rewound.
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
    /// Slot → value. Hot path for OP_GET/SET_GLOBAL.
    global_values: []Value = &.{},
    global_count: u16 = 0,
    /// Name → slot (builtin register + rare dynamic lookup only).
    global_name_to_slot: std.StringHashMap(u16),
    stack_buf: []Value = &.{},
    sp: usize = 0,
    frames: std.ArrayList(CallFrame) = .empty,
    /// Frame-local Value heap. Grows; rewind is `heap_ptr` (capacity retained).
    memory: std.ArrayList(Value) = .empty,
    heap_ptr: i32 = HEAP_START,
    /// Pass-/process-lifetime Values (arenas, errors, escaped `@new`). Grows only.
    immortal: std.ArrayList(Value) = .empty,
    free_chunks: i32 = 0,
    /// Packed byte heap (`[]byte` / `[N]byte`). Append-only, grows as needed.
    bytes: std.ArrayList(u8) = .empty,
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
    max_memory_slots: usize = 1048576,

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk, max_memory_slots: usize) !VMState {
        const headroom: usize = 512;
        const initial_globals = @max(chunk.global_names.items.len + headroom, headroom);
        var state: VMState = .{
            .allocator = allocator,
            .global_name_to_slot = std.StringHashMap(u16).init(allocator),
            .string_cache = std.AutoHashMap(u32, i32).init(allocator),
            .chunk = chunk,
            .max_memory_slots = max_memory_slots,
            .stack_buf = try allocator.alloc(Value, STACK_MAX),
            .global_values = try allocator.alloc(Value, initial_globals),
        };
        @memset(state.stack_buf, .null);
        @memset(state.global_values, .null);
        for (chunk.global_names.items, 0..) |name, i| {
            try state.global_name_to_slot.put(name, @intCast(i));
        }
        state.global_count = @intCast(chunk.global_names.items.len);
        try state.memory.appendNTimes(allocator, .null, @intCast(HEAP_START));
        try state.memory.ensureTotalCapacity(allocator, 4096);
        try state.immortal.ensureTotalCapacity(allocator, 256);
        try state.bytes.ensureTotalCapacity(allocator, 4096);
        var frame = CallFrame.init(allocator);
        frame.func_name = "<anonymous>";
        frame.file = if (chunk.file.len > 0) chunk.file else "<anonymous>";
        frame.source_index = 0;
        // Script frame lives until process end — watermark tracks immortal growth.
        frame.heap_watermark = HEAP_START;
        try state.frames.append(allocator, frame);
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
        self.allocator.free(self.stack_buf);
        self.allocator.free(self.global_values);
        self.global_name_to_slot.deinit();
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
        self.memory.deinit(self.allocator);
        self.immortal.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
    }

    /// Frame-local bump. Rewound when the current call returns (see `doReturn`).
    pub fn allocSlots(self: *VMState, count: i32) !i32 {
        if (count < 0) return error.OutOfMemory;
        const ptr = self.heap_ptr;
        const new_ptr = ptr + count;
        const new_len: usize = @intCast(new_ptr);
        if (new_len > self.max_memory_slots) return error.OutOfMemory;
        if (new_len > self.memory.items.len) {
            try self.memory.resize(self.allocator, new_len);
        }
        @memset(self.memory.items[@intCast(ptr)..new_len], .null);
        self.heap_ptr = new_ptr;
        return ptr;
    }

    /// Process-/pass-lifetime bump (arenas, `error(…)`, values meant to escape a frame).
    /// Separate growable list so frame rewind cannot clobber escaped data.
    pub fn allocImmortal(self: *VMState, count: i32) !i32 {
        if (count < 0) return error.OutOfMemory;
        const idx: i32 = @intCast(self.immortal.items.len);
        const new_len = self.immortal.items.len + @as(usize, @intCast(count));
        if (new_len > self.max_memory_slots) return error.OutOfMemory;
        try self.immortal.resize(self.allocator, new_len);
        @memset(self.immortal.items[@intCast(idx)..], .null);
        return IMMORTAL_BASE + idx;
    }

    pub fn isImmortalPtr(ptr: i32) bool {
        return ptr >= IMMORTAL_BASE;
    }

    pub fn isValidHeapPtr(self: *const VMState, ptr: i64) bool {
        if (ptr >= IMMORTAL_BASE) {
            const i = ptr - IMMORTAL_BASE;
            return i >= 0 and i < @as(i64, @intCast(self.immortal.items.len));
        }
        if (ptr < HEAP_START) return false;
        return ptr < self.heap_ptr;
    }

    /// Load/store a heap slot. Frame indices are `HEAP_START..heap_ptr`;
    /// immortal indices are `IMMORTAL_BASE + i`.
    pub fn slot(self: *VMState, ptr: i32) *Value {
        if (ptr >= IMMORTAL_BASE) {
            return &self.immortal.items[@intCast(ptr - IMMORTAL_BASE)];
        }
        return &self.memory.items[@intCast(ptr)];
    }

    /// Packed bytes for `@new(a, []byte, n)` / `[N]byte`. Grows as needed.
    pub fn allocImmortalBytes(self: *VMState, count: i32) !i32 {
        if (count < 0) return error.OutOfMemory;
        const new_len = self.bytes.items.len + @as(usize, @intCast(count));
        if (new_len > self.max_memory_slots * 16) return error.OutOfMemory;
        const ptr: i32 = @intCast(self.bytes.items.len);
        try self.bytes.appendNTimes(self.allocator, 0, @intCast(count));
        return ptr;
    }

    pub fn packedBytes(self: *VMState, offset: u32, len: u32) []u8 {
        return self.bytes.items[offset..][0..len];
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

    pub fn ensureGlobalCapacity(self: *VMState, need: usize) !void {
        if (need <= self.global_values.len) return;
        var new_cap = self.global_values.len;
        if (new_cap == 0) new_cap = 64;
        while (new_cap < need) new_cap *= 2;
        const old_len = self.global_values.len;
        self.global_values = try self.allocator.realloc(self.global_values, new_cap);
        @memset(self.global_values[old_len..new_cap], .null);
    }

    /// Register or update a global by name (builtins / rare dynamic). Hot bytecode uses slots.
    pub fn defineGlobal(self: *VMState, name: []const u8, v: Value) !void {
        if (self.global_name_to_slot.get(name)) |gs| {
            self.global_values[gs] = v;
            return;
        }
        if (self.global_count == std.math.maxInt(u16)) return error.OutOfMemory;
        const gs = self.global_count;
        try self.ensureGlobalCapacity(@as(usize, gs) + 1);
        try self.global_name_to_slot.put(name, gs);
        self.global_values[gs] = v;
        self.global_count += 1;
    }

    pub fn getGlobalSlot(self: *const VMState, gs: u16) ?Value {
        if (gs >= self.global_count) return null;
        return self.global_values[gs];
    }

    pub fn setGlobalSlot(self: *VMState, gs: u16, v: Value) !void {
        if (gs >= self.global_count) {
            // Allow writing compiler-reserved slots that init already counted.
            if (gs < self.chunk.global_names.items.len) {
                try self.ensureGlobalCapacity(@as(usize, gs) + 1);
                self.global_count = @intCast(self.chunk.global_names.items.len);
            } else return error.OutOfMemory;
        }
        self.global_values[gs] = v;
    }
};

test "frame heap grows past initial capacity" {
    var c = chunk_mod.Chunk.init(std.testing.allocator);
    defer c.deinit();
    var vm = try VMState.init(std.testing.allocator, &c, 1048576);
    defer vm.deinit();

    const a = try vm.allocSlots(8000);
    try std.testing.expectEqual(HEAP_START, a);
    try std.testing.expectEqual(HEAP_START + 8000, vm.heap_ptr);
    vm.slot(a).* = .{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), vm.slot(a).*.int);
}

test "immortal heap and packed bytes grow" {
    var c = chunk_mod.Chunk.init(std.testing.allocator);
    defer c.deinit();
    var vm = try VMState.init(std.testing.allocator, &c, 1048576);
    defer vm.deinit();

    const p = try vm.allocImmortal(3);
    try std.testing.expect(p >= IMMORTAL_BASE);
    vm.slot(p).* = .{ .int = 7 };
    _ = try vm.allocImmortal(5000);
    try std.testing.expect(vm.immortal.items.len >= 5003);
    try std.testing.expectEqual(@as(i64, 7), vm.slot(p).*.int);

    const off = try vm.allocImmortalBytes(2 * 1024 * 1024);
    try std.testing.expect(vm.bytes.items.len >= 2 * 1024 * 1024);
    vm.bytes.items[@intCast(off)] = 9;
    vm.bytes.items[@intCast(off + 2 * 1024 * 1024 - 1)] = 8;
    try std.testing.expectEqual(@as(u8, 9), vm.bytes.items[@intCast(off)]);
    try std.testing.expectEqual(@as(u8, 8), vm.bytes.items[@intCast(off + 2 * 1024 * 1024 - 1)]);
}
