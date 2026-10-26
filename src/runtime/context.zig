//! Execution context — native counterpart to `VMState`: frame watermarks,
//! packed heap (pending extraction), and the LLTS shadow call stack used for
//! trap diagnostics.
//!
//! Emitted functions use `enterFunction` / `leaveFunction` around their body
//! and `setLine` at statement boundaries (debug builds). The shadow stack is
//! what lets the runtime print `at fn (file:line:col)` traces instead of
//! relying on Zig's panic or error-return traces.

const std = @import("std");
const io = @import("io.zig");
const trace = @import("trace.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    /// LLTS call frames for trap stack traces (`VMState.frames` parity).
    trace_stack: trace.ShadowStack = .{},

    /// Paired with `enterFunction`; remembers whether a shadow frame was
    /// actually pushed so `leaveFunction` never pops someone else's frame.
    pub const FunctionMark = struct {
        frame: usize,
        traced: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Context) void {
        self.deactivate();
    }

    /// Register this context as the active one for trap diagnostics. The
    /// emitted `main` glue calls this immediately after `init` — the address
    /// cannot be taken inside `init` because the returned Context is still a
    /// local copy there.
    pub fn activate(self: *Context) void {
        trace.active = &self.trace_stack;
    }

    pub fn deactivate(self: *Context) void {
        if (trace.active == &self.trace_stack) trace.active = null;
    }

    // --- Call frames --------------------------------------------------------

    /// Prologue: watermark + shadow-stack push. Traps when the LLTS frame cap
    /// is hit (the VM's `TooManyFrames`, one clear message).
    pub fn enterFunction(self: *Context, func_name: []const u8, file: []const u8) error{RuntimeError}!FunctionMark {
        const frame = self.enterFrame();
        self.trace_stack.push(func_name, file) catch {
            self.leaveFrame(frame);
            return io.fail("Maximum call stack depth exceeded ({d} frames)", .{trace.MAX_FRAMES}) catch |err| return err;
        };
        return .{ .frame = frame, .traced = true };
    }

    /// Epilogue: mirror of `enterFunction`; safe on every exit path.
    pub fn leaveFunction(self: *Context, mark: FunctionMark) void {
        if (mark.traced) self.trace_stack.pop();
        self.leaveFrame(mark.frame);
    }

    /// `OP_LINE` equivalent: keep the innermost frame's location current.
    /// Release builds omit these calls, exactly like stripped `OP_LINE`s.
    pub fn setLine(self: *Context, line: u32, column: u32) void {
        self.trace_stack.setLoc(line, column);
    }

    // --- Frame watermarks ---------------------------------------------------

    /// Save the current frame watermark before entering a new call frame.
    pub fn enterFrame(_: *Context) usize {
        return 0;
    }

    /// Rewind the heap bump pointer to the saved watermark on function exit.
    pub fn leaveFrame(_: *Context, _: usize) void {}
};
