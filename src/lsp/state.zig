const std = @import("std");
const analysis_mod = @import("analysis.zig");

pub const DocumentEntry = struct {
    /// Owned by server.allocator; all analyses reference this slice.
    text: []const u8,
    /// Last version reported by the client (-1 when unknown).
    client_version: i32 = -1,
    /// Bumped on every text change; used to key the cached analysis.
    stamp: u64 = 0,
    /// Cached analysis for the current stamp, or null when dirty.
    analysis: ?*analysis_mod.Analysis = null,
};

/// A debounced diagnostics publish for one document. `uri` is owned by
/// server.allocator; `deadline_ms` is a `std.time.milliTimestamp()` value.
pub const PendingDiag = struct {
    uri: []const u8,
    deadline_ms: i64,
};

/// How long didChange waits before re-running diagnostics (trailing debounce;
/// each further edit pushes the deadline back).
pub const DIAG_DEBOUNCE_MS: i64 = 250;

pub const ServerState = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap(DocumentEntry),
    /// Diagnostics publishes waiting for their debounce deadline.
    pending_diags: std.ArrayList(PendingDiag) = .empty,

    pub fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap(DocumentEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ServerState) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.freeAnalysis(&entry.value_ptr.analysis);
            self.allocator.free(entry.value_ptr.text);
            self.allocator.free(entry.key_ptr.*);
        }
        self.documents.deinit();
        for (self.pending_diags.items) |p| self.allocator.free(p.uri);
        self.pending_diags.deinit(self.allocator);
    }

    fn freeAnalysis(self: *ServerState, slot: *?*analysis_mod.Analysis) void {
        if (slot.*) |a| {
            a.deinit();
            self.allocator.destroy(a);
            slot.* = null;
        }
    }

    /// Store new document text. Any cached analysis is dropped (lazily rebuilt).
    pub fn updateDocument(self: *ServerState, uri: []const u8, text: []const u8, client_version: ?i32) !void {
        const gop = try self.documents.getOrPut(uri);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, uri);
        } else {
            self.freeAnalysis(&gop.value_ptr.analysis);
            self.allocator.free(gop.value_ptr.text);
        }
        gop.value_ptr.* = .{
            .text = try self.allocator.dupe(u8, text),
            .client_version = client_version orelse -1,
            .stamp = gop.value_ptr.stamp + 1,
            .analysis = null,
        };
    }

    pub fn removeDocument(self: *ServerState, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            var value = kv.value;
            self.freeAnalysis(&value.analysis);
            self.allocator.free(value.text);
            self.allocator.free(kv.key);
        }
        self.cancelPendingDiagnostics(uri);
    }

    /// Schedule (or reschedule) a debounced diagnostics publish for `uri`.
    /// Trailing debounce: every call pushes the deadline out.
    pub fn scheduleDiagnostics(self: *ServerState, uri: []const u8, now_ms: i64) !void {
        const deadline = now_ms + DIAG_DEBOUNCE_MS;
        for (self.pending_diags.items) |*p| {
            if (std.mem.eql(u8, p.uri, uri)) {
                p.deadline_ms = deadline;
                return;
            }
        }
        try self.pending_diags.append(self.allocator, .{
            .uri = try self.allocator.dupe(u8, uri),
            .deadline_ms = deadline,
        });
    }

    /// Drop a pending publish (document closed).
    pub fn cancelPendingDiagnostics(self: *ServerState, uri: []const u8) void {
        var i: usize = 0;
        while (i < self.pending_diags.items.len) {
            if (std.mem.eql(u8, self.pending_diags.items[i].uri, uri)) {
                const p = self.pending_diags.swapRemove(i);
                self.allocator.free(p.uri);
            } else {
                i += 1;
            }
        }
    }

    /// Milliseconds until the earliest pending deadline (0 if due now).
    /// Returns null when nothing is pending (poll may block indefinitely).
    pub fn nextDiagnosticsTimeout(self: *ServerState, now_ms: i64) ?i32 {
        var earliest: ?i64 = null;
        for (self.pending_diags.items) |p| {
            if (earliest == null or p.deadline_ms < earliest.?) earliest = p.deadline_ms;
        }
        const e = earliest orelse return null;
        if (e <= now_ms) return 0;
        const ms = e - now_ms;
        return @intCast(@min(ms, std.math.maxInt(i32)));
    }

    /// Remove and return uris whose debounce deadline has passed. Returned
    /// slices are duped into `ra`; caller must publish or drop them.
    pub fn collectDueDiagnostics(self: *ServerState, ra: std.mem.Allocator, now_ms: i64) ![][]const u8 {
        var due: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < self.pending_diags.items.len) {
            const p = self.pending_diags.items[i];
            if (p.deadline_ms <= now_ms) {
                try due.append(ra, try ra.dupe(u8, p.uri));
                self.allocator.free(p.uri);
                _ = self.pending_diags.swapRemove(i);
            } else {
                i += 1;
            }
        }
        return due.items;
    }

    pub fn getDocument(self: *ServerState, uri: []const u8) ?[]const u8 {
        return if (self.documents.getPtr(uri)) |entry| entry.text else null;
    }

    pub fn getEntry(self: *ServerState, uri: []const u8) ?*DocumentEntry {
        return self.documents.getPtr(uri);
    }

    /// Return the cached analysis for `uri`, analyzing on demand.
    /// The result is owned by the server state and stays valid until the
    /// document text changes or the document is removed.
    pub fn ensureAnalysis(self: *ServerState, uri: []const u8) !*analysis_mod.Analysis {
        const entry = self.documents.getPtr(uri) orelse return error.DocumentNotFound;

        if (entry.analysis) |a| return a;

        // The analysis must live at a stable address BEFORE it is populated:
        // child structures capture the arena's address during analysis.
        const a = try analysis_mod.create(self.allocator, uri, entry.text);
        errdefer {
            a.deinit();
            self.allocator.destroy(a);
        }

        try analysis_mod.analyzeInPlace(a, entry.stamp);

        entry.analysis = a;
        return a;
    }
};

test "scheduleDiagnostics debounces and collects due" {
    const allocator = std.testing.allocator;
    var server = ServerState.init(allocator);
    defer server.deinit();

    try server.updateDocument("file:///a.lls", "x", 1);
    try server.scheduleDiagnostics("file:///a.lls", 1000);
    // A second schedule for the same uri reschedules rather than duplicating.
    try server.scheduleDiagnostics("file:///a.lls", 1100);
    try std.testing.expectEqual(@as(usize, 1), server.pending_diags.items.len);

    // Not due yet: 250ms out from 1100.
    try std.testing.expectEqual(@as(?i32, 250), server.nextDiagnosticsTimeout(1100));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const due_none = try server.collectDueDiagnostics(arena.allocator(), 1100);
    try std.testing.expectEqual(@as(usize, 0), due_none.len);

    const due = try server.collectDueDiagnostics(arena.allocator(), 1350);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("file:///a.lls", due[0]);
    try std.testing.expectEqual(@as(?i32, null), server.nextDiagnosticsTimeout(1350));
}

test "removeDocument cancels pending diagnostics" {
    const allocator = std.testing.allocator;
    var server = ServerState.init(allocator);
    defer server.deinit();

    try server.updateDocument("file:///b.lls", "x", 1);
    try server.scheduleDiagnostics("file:///b.lls", 0);
    server.removeDocument("file:///b.lls");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const due = try server.collectDueDiagnostics(arena.allocator(), 1_000_000);
    try std.testing.expectEqual(@as(usize, 0), due.len);
    try std.testing.expectEqual(@as(?i32, null), server.nextDiagnosticsTimeout(0));
}
