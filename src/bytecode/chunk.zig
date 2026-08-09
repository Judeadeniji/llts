const std = @import("std");
const value = @import("value.zig");

pub const Value = value.Value;
pub const LltsFunction = value.LltsFunction;
pub const NativeFunction = value.NativeFunction;

pub const Chunk = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    constants: std.ArrayList(Value) = .empty,
    /// Parallel string storage for name/string constants (owned).
    strings: std.ArrayList([]const u8) = .empty,
    functions: std.StringHashMap(LltsFunction),
    exports: std.StringHashMap(void),
    file: []const u8 = "<anonymous>",
    source: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .allocator = allocator,
            .functions = std.StringHashMap(LltsFunction).init(allocator),
            .exports = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Chunk) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.functions.deinit();
        self.exports.deinit();
    }

    pub fn write(self: *Chunk, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    pub fn writeOp(self: *Chunk, op: @import("opcode.zig").OpCode) !void {
        try self.write(@intFromEnum(op));
    }

    pub fn addConstant(self: *Chunk, v: Value) !u8 {
        const idx = self.constants.items.len;
        if (idx >= 256) return error.TooManyConstants;
        try self.constants.append(self.allocator, v);
        return @intCast(idx);
    }

    pub fn internString(self: *Chunk, s: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, s);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    pub fn addStringConstant(self: *Chunk, s: []const u8) !u8 {
        const owned = try self.internString(s);
        // Store as name index into strings for now; MAKE_STRING / print resolve later.
        const name_idx: u32 = @intCast(self.strings.items.len - 1);
        _ = owned;
        return try self.addConstant(.{ .name = name_idx });
    }

    pub fn stringAt(self: *const Chunk, idx: u32) []const u8 {
        return self.strings.items[idx];
    }
};
