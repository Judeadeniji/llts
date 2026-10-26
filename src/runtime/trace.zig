//! LLTS shadow call stack and trap-frame formatting for native programs.
//!
//! The VM walks `VMState.frames` when a runtime trap fires, so interpreter
//! diagnostics show `at fn (file:line:col)` for every active LLTS call. Native
//! code runs on Zig's real call stack, which knows nothing about LLTS names or
//! source locations. This module mirrors LLTS calls in a fixed array so the
//! trap path can print the same trace. LLTS owns the failure report end to
//! end: Zig panics and Zig error traces are never user-visible.
//!
//! Emitted functions push on entry and pop on exit (`Context.enterFunction` /
//! `Context.leaveFunction`); debug builds update the innermost frame at
//! statement boundaries (`Context.setLine`, the `OP_LINE` equivalent).
//! Traps still return `error.RuntimeError` internally as the unwind signal —
//! the emitted `main` glue is the single sink and exits 1 after the trace has
//! been printed.

const std = @import("std");

/// Matches `vm/state.zig` MAX_FRAMES so VM and native traces cap alike.
pub const MAX_FRAMES: usize = 256;

pub const Frame = struct {
    func_name: []const u8 = "<anonymous>",
    file: []const u8 = "",
    line: u32 = 0,
    column: u32 = 0,
};

/// Format one frame exactly like the VM's `formatVmStackTrace` (sans color):
/// `    at name (file:line:col)\n`, or `?:?` while the location is unknown.
/// The location is unknown in release builds, which strip line updates the
/// same way the bytecode compiler strips `OP_LINE`.
pub fn formatFrame(buf: []u8, frame: Frame) []const u8 {
    const file = if (frame.file.len > 0) frame.file else "<anonymous>";
    return if (frame.line > 0)
        std.fmt.bufPrint(buf, "    at {s} ({s}:{d}:{d})\n", .{ frame.func_name, file, frame.line, frame.column }) catch buf[0..0]
    else
        std.fmt.bufPrint(buf, "    at {s} ({s}:?:?)\n", .{ frame.func_name, file }) catch buf[0..0];
}

pub const ShadowStack = struct {
    frames: [MAX_FRAMES]Frame = undefined,
    count: usize = 0,

    /// Record a call. The location starts unknown; `setLoc` fills it in at the
    /// callee's first statement.
    pub fn push(self: *ShadowStack, func_name: []const u8, file: []const u8) error{StackOverflow}!void {
        if (self.count >= MAX_FRAMES) return error.StackOverflow;
        self.frames[self.count] = .{ .func_name = func_name, .file = file };
        self.count += 1;
    }

    pub fn pop(self: *ShadowStack) void {
        if (self.count > 0) self.count -= 1;
    }

    /// `OP_LINE` equivalent: move the innermost frame's source location.
    pub fn setLoc(self: *ShadowStack, line: u32, column: u32) void {
        if (self.count == 0) return;
        self.frames[self.count - 1].line = line;
        self.frames[self.count - 1].column = column;
    }
};

/// The active context's shadow stack (the runtime is single-threaded). Set by
/// `Context.activate`; the trap path reads it even from ctx-less op helpers.
pub var active: ?*ShadowStack = null;

/// Print the active trace innermost-first (VM `formatVmStackTrace` order).
pub fn printActive(sink: *const fn ([]const u8) void) void {
    const stack = active orelse return;
    var buf: [320]u8 = undefined;
    var i: usize = stack.count;
    while (i > 0) {
        i -= 1;
        const line = formatFrame(&buf, stack.frames[i]);
        if (line.len > 0) sink(line);
    }
}
