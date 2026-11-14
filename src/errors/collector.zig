const std = @import("std");
const color = @import("../io/color.zig");
const diag = @import("diag.zig");
const io_out = @import("../io/out.zig");

pub const Severity = enum { err, warning };

/// A single recorded diagnostic. `path`/`source` are copied because compiler
/// state (and its owned source buffers) may be torn down before diagnostics
/// are printed.
pub const Diagnostic = struct {
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
    frames: std.ArrayList(Frame) = .empty,
    severity: Severity = .err,
};

pub const Frame = struct {
    path: []const u8,
    line: u32,
    column: u32,
    name: []const u8,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    cap: usize = 100,
    truncated: usize = 0,
    seen: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, cap: usize) Collector {
        return .{
            .allocator = allocator,
            .cap = cap,
            .seen = std.StringHashMap(void).init(allocator),
        };
    }

    fn freeDiagnostic(allocator: std.mem.Allocator, d: *Diagnostic) void {
        allocator.free(d.path);
        allocator.free(d.source);
        allocator.free(d.message);
        for (d.frames.items) |*f| {
            allocator.free(f.path);
            allocator.free(f.name);
        }
        d.frames.deinit(allocator);
    }

    pub fn deinit(self: *Collector) void {
        for (self.items.items) |*d| {
            freeDiagnostic(self.allocator, d);
        }
        self.items.deinit(self.allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.seen.deinit();
    }

    /// Build a dedup key from path/line/column/message.
    fn dedupKey(self: *Collector, path: []const u8, line: u32, column: u32, message: []const u8) ![]u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}\x00{d}\x00{d}\x00{s}",
            .{ path, line, column, message },
        );
    }

    /// Record a diagnostic. Returns true when stored, false when dropped
    /// because the error cap was reached (warnings are never capped).
    pub fn add(
        self: *Collector,
        path: []const u8,
        source: []const u8,
        line: u32,
        column: u32,
        message: []const u8,
        severity: Severity,
    ) bool {
        const owned_path = self.allocator.dupe(u8, path) catch return false;
        const owned_source = self.allocator.dupe(u8, source) catch {
            self.allocator.free(owned_path);
            return false;
        };
        const msg = self.allocator.dupe(u8, message) catch {
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            return false;
        };

        if (severity == .warning) {
            const d = Diagnostic{
                .path = owned_path,
                .source = owned_source,
                .line = line,
                .column = column,
                .message = msg,
                .severity = .warning,
            };
            self.items.append(self.allocator, d) catch {
                self.allocator.free(owned_path);
                self.allocator.free(owned_source);
                self.allocator.free(msg);
                return false;
            };
            return true;
        }

        const key = self.dedupKey(owned_path, line, column, message) catch {
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            self.allocator.free(msg);
            return false;
        };
        if (self.seen.contains(key)) {
            self.allocator.free(key);
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            self.allocator.free(msg);
            return true;
        }

        if (self.cap != 0 and self.items.items.len >= self.cap) {
            self.allocator.free(key);
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            self.allocator.free(msg);
            self.truncated += 1;
            return false;
        }

        self.seen.put(key, {}) catch {
            self.allocator.free(key);
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            self.allocator.free(msg);
            return false;
        };
        const d = Diagnostic{
            .path = owned_path,
            .source = owned_source,
            .line = line,
            .column = column,
            .message = msg,
            .severity = .err,
        };
        self.items.append(self.allocator, d) catch {
            _ = self.seen.remove(key);
            self.allocator.free(key);
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            self.allocator.free(msg);
            return false;
        };
        return true;
    }

    /// Attach a frame to the most recently added diagnostic.
    pub fn addFrame(
        self: *Collector,
        path: []const u8,
        line: u32,
        column: u32,
        name: []const u8,
    ) void {
        if (self.items.items.len == 0) return;
        const owned_path = self.allocator.dupe(u8, path) catch return;
        const nm = self.allocator.dupe(u8, name) catch {
            self.allocator.free(owned_path);
            return;
        };
        const last = &self.items.items[self.items.items.len - 1];
        _ = last.frames.append(self.allocator, .{
            .path = owned_path,
            .line = line,
            .column = column,
            .name = nm,
        }) catch {
            self.allocator.free(owned_path);
            self.allocator.free(nm);
        };
    }

    pub fn hasErrors(self: *Collector) bool {
        for (self.items.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    pub fn errorCount(self: *Collector) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.severity == .err) n += 1;
        }
        return n;
    }

    /// Sort by path/line/column, dedupe, print each diagnostic, print a
    /// summary line, print a suppressed-count note when capped, and call
    /// `diag.markEmitted()`.
    pub fn reportAll(self: *Collector) void {
        std.mem.sort(Diagnostic, self.items.items, {}, struct {
            fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
                if (std.mem.lessThan(u8, a.path, b.path)) return true;
                if (!std.mem.eql(u8, a.path, b.path)) return false;
                if (a.line != b.line) return a.line < b.line;
                return a.column < b.column;
            }
        }.lessThan);

        // `add` already dedupes via `seen`; sorting is enough for ordering.
        const err_count = self.errorCount();

        for (self.items.items) |d| {
            const c_err = color.paint(color.bold ++ color.bright_red);
            const c_arrow = color.paint(color.bold ++ color.bright_cyan);
            const c_num = color.paint(color.blue);
            const c_caret = color.paint(color.bold ++ color.bright_cyan);
            const c_dim = color.paint(color.dim);
            const c_name = color.paint(color.cyan);
            const c_warn = color.paint(color.bold ++ color.bright_yellow);
            const r = color.r();

            if (d.severity == .warning) {
                io_out.printStderr("{s}Warning{s}: {s}", .{c_warn, r, d.message});
                io_out.printStderr("\n", .{});
            } else {
                io_out.printStderr("{s}Error{s}: {s}", .{c_err, r, d.message});
                io_out.printStderr("\n", .{});
            }
            io_out.printStderr("  {s}-->{s} {s}:{d}:{d}\n", .{c_arrow, r, d.path, d.line, d.column});

            var current: u32 = 1;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= d.source.len) : (i += 1) {
                if (i == d.source.len or d.source[i] == '\n') {
                    if (current == d.line) {
                        const line_src = d.source[start..i];
                        io_out.printStderr("   {s}{d}{s} | {s}\n", .{c_num, d.line, r, line_src});
                        io_out.printStderr("     | ", .{});
                        var c: u32 = 1;
                        const col = if (d.column == 0) 1 else d.column;
                        while (c < col) : (c += 1) io_out.printStderr(" ", .{});
                        io_out.printStderr("{s}^{s}\n", .{c_caret, r});
                        break;
                    }
                    current += 1;
                    start = i + 1;
                }
            }

            for (d.frames.items) |f| {
                io_out.printStderr("    {s}at{s} {s}{s}{s} ({s}:{d}:{d})\n", .{
                    c_dim, r, c_name, f.name, r, f.path, f.line, f.column,
                });
            }
        }

        if (err_count > 0) {
            io_out.printStderr("Compilation failed with {d} error{s}.\n", .{
                err_count,
                if (err_count == 1) "" else "s",
            });
        }
        if (self.truncated > 0) {
            io_out.printStderr("{d} further error{s} suppressed (--max-errors limit).\n", .{
                self.truncated,
                if (self.truncated == 1) "" else "s",
            });
        }

        diag.markEmitted();
    }

    pub fn wasEmitted() bool {
        return diag.wasEmitted();
    }
};

var active: ?*Collector = null;

pub fn setActive(c: ?*Collector) void {
    active = c;
}

pub fn getActive() ?*Collector {
    return active;
}

pub fn clearActive() void {
    active = null;
}
