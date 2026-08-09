const std = @import("std");

pub fn reportSourceError(
    path: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
) void {
    // Match TS diagnostics closely enough for tests (`Error:`, `--> path:line:col`).
    std.debug.print("{s}: Error: {s}\n", .{ path, message });
    std.debug.print("  --> {s}:{d}:{d}\n", .{ path, line, column });

    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (current == line) {
                const line_src = source[start..i];
                std.debug.print("   {d} | {s}\n", .{ line, line_src });
                std.debug.print("     | ", .{});
                var c: u32 = 1;
                while (c < column) : (c += 1) std.debug.print(" ", .{});
                std.debug.print("^\n", .{});
                break;
            }
            current += 1;
            start = i + 1;
        }
    }
}

pub fn reportLocationFrame(path: []const u8, line: u32, name: []const u8) void {
    std.debug.print("    at {s} ({s}:{d})\n", .{ name, path, line });
}

pub fn reportCompileMessage(message: []const u8) void {
    std.debug.print("Error: {s}\n", .{message});
}
