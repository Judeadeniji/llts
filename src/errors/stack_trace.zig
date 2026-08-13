const out = @import("../io/out.zig");
const color = @import("../io/color.zig");
const state_mod = @import("../vm/state.zig");
const diag = @import("diag.zig");

pub fn formatVmStackTrace(frames: []const state_mod.CallFrame) void {
    diag.markEmitted();
    const c_dim = color.paint(color.dim);
    const c_name = color.paint(color.cyan);
    const r = color.r();
    var i: isize = @intCast(frames.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const f = frames[@intCast(i)];
        const file = if (f.file.len > 0) f.file else "<anonymous>";
        const ln = if (f.line > 0) f.line else 1;
        const col = if (f.column > 0) f.column else 1;
        out.printStderr("    {s}at{s} {s}{s}{s} ({s}:{d}:{d})\n", .{ c_dim, r, c_name, f.func_name, r, file, ln, col });
    }
}

pub fn reportStackTrace(frames: []const state_mod.CallFrame) void {
    formatVmStackTrace(frames);
}

/// Back-compat wrapper used by older call sites (ignores shared file/line).
pub fn reportStackTraceLegacy(frames: []const state_mod.CallFrame, file: []const u8, line: u32) void {
    _ = file;
    _ = line;
    formatVmStackTrace(frames);
}
