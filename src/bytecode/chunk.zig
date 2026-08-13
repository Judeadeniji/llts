const std = @import("std");
const value = @import("value.zig");

pub const Value = value.Value;
pub const LltsFunction = value.LltsFunction;
pub const NativeFunction = value.NativeFunction;

pub const SourceFile = struct {
    path: []const u8,
    text: []const u8,
};

pub const Chunk = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    constants: std.ArrayList(Value) = .empty,
    /// Parallel string storage for name/string constants (owned).
    strings: std.ArrayList([]const u8) = .empty,
    functions: std.StringHashMap(LltsFunction),
    exports: std.StringHashMap(void),
    /// Entry script path (sources[0].path when sources non-empty).
    file: []const u8 = "<anonymous>",
    /// Entry script text (sources[0].text when sources non-empty).
    source: []const u8 = "",
    /// All source files (entry + imports). Paths/text are borrowed, not owned.
    sources: std.ArrayList(SourceFile) = .empty,

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
        for (self.sources.items) |s| {
            self.allocator.free(s.path);
            self.allocator.free(s.text);
        }
        self.sources.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.functions.deinit();
        self.exports.deinit();
    }

    /// Register a source file; returns its index. Dedupes by path.
    /// Owns copies of path and text (safe after compiler state frees imports).
    pub fn addSource(self: *Chunk, path: []const u8, text: []const u8) !u16 {
        for (self.sources.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.path, path)) return @intCast(i);
        }
        const idx = self.sources.items.len;
        if (idx >= 65536) return error.TooManyConstants;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.sources.append(self.allocator, .{ .path = owned_path, .text = owned_text });
        return @intCast(idx);
    }

    pub fn sourceAt(self: *const Chunk, idx: u16) SourceFile {
        if (idx < self.sources.items.len) return self.sources.items[idx];
        return .{ .path = self.file, .text = self.source };
    }

    pub fn write(self: *Chunk, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    pub fn writeOp(self: *Chunk, op: @import("opcode.zig").OpCode) !void {
        try self.write(@intFromEnum(op));
    }

    pub fn addConstant(self: *Chunk, v: Value) !u16 {
        const idx = self.constants.items.len;
        if (idx >= 65536) return error.TooManyConstants;
        try self.constants.append(self.allocator, v);
        return @intCast(idx);
    }

    pub fn internString(self: *Chunk, s: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, s);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    pub fn addStringConstant(self: *Chunk, s: []const u8) !u16 {
        // Deduplicate: reuse an existing constant slot for the same name.
        for (self.constants.items, 0..) |c, i| {
            if (c == .name) {
                if (std.mem.eql(u8, self.strings.items[c.name], s)) {
                    return @intCast(i);
                }
            }
        }
        const owned = try self.allocator.dupe(u8, s);
        try self.strings.append(self.allocator, owned);
        const name_idx: u32 = @intCast(self.strings.items.len - 1);
        return try self.addConstant(.{ .name = name_idx });
    }

    pub fn stringAt(self: *const Chunk, idx: u32) []const u8 {
        return self.strings.items[idx];
    }
};
