const std = @import("std");
const state_mod = @import("../vm/state.zig");

pub fn formatVmStackTrace(frames: []const state_mod.CallFrame, file: []const u8, line: u32) void {
    var i: isize = @intCast(frames.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const f = frames[@intCast(i)];
        const ln = if (i == @as(isize, @intCast(frames.len - 1))) line else f.line;
        std.debug.print("    at {s} ({s}:{d})\n", .{ f.func_name, file, ln });
    }
}

pub fn reportStackTrace(frames: []const state_mod.CallFrame, file: []const u8, line: u32) void {
    formatVmStackTrace(frames, file, line);
}
