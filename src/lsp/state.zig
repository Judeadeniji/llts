const std = @import("std");

pub const ServerState = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ServerState) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.documents.deinit();
    }

    pub fn updateDocument(self: *ServerState, uri: []const u8, text: []const u8) !void {
        const key = try self.allocator.dupe(u8, uri);
        const val = try self.allocator.dupe(u8, text);
        
        if (self.documents.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        
        try self.documents.put(key, val);
    }

    pub fn removeDocument(self: *ServerState, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    pub fn getDocument(self: *ServerState, uri: []const u8) ?[]const u8 {
        return self.documents.get(uri);
    }
};
