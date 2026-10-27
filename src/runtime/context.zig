//! Execution context — the native counterpart to `VMState`'s memory model and
//! call stack.
//!
//! Two append-only bump buffers with fixed capacity (pointers handed out by
//! the runtime never move, so emitted code can hold raw slices/pointers across
//! calls):
//!   * `frame`   — per-call-frame scratch; rewound by `leaveFrame`.
//!   * `immortal` — program-lifetime values (string literals, concatenated
//!     strings, anything the compiler marks immortal); never rewound.
//!
//! Exhaustion traps (`error.OutOfMemory` for now; the emitter maps it to a
//! runtime diagnostic) instead of reallocating, because a realloc would move
//! the backing store and invalidate every previously handed-out pointer.
//!
//! The same context owns the LLTS shadow call stack used for trap
//! diagnostics: emitted functions use `enterFunction` / `leaveFunction`
//! around their body and `setLine` at statement boundaries (debug builds).
//! That is what lets the runtime print `at fn (file:line:col)` traces instead
//! of relying on Zig's panic or error-return traces.

const std = @import("std");
const io = @import("io.zig");
const trace = @import("trace.zig");

/// Matches the VM packed-heap capacity: max_memory_slots (1<<20) * 16 bytes.
pub const DEFAULT_FRAME_CAPACITY: usize = 1024 * 1024 * 16;
/// VM immortal window is 1 GiB; native default is a modest 16 MiB that
/// programs can raise via `Options` when they need large literal pools.
pub const DEFAULT_IMMORTAL_CAPACITY: usize = 1024 * 1024 * 16;

pub const Context = struct {
    allocator: std.mem.Allocator,
    frame: []u8 = &.{},
    frame_len: usize = 0,
    immortal: []u8 = &.{},
    immortal_len: usize = 0,
    /// LLTS call frames for trap stack traces (`VMState.frames` parity).
    trace_stack: trace.ShadowStack = .{},

    pub const Options = struct {
        allocator: ?std.mem.Allocator = null,
        frame_capacity: usize = DEFAULT_FRAME_CAPACITY,
        immortal_capacity: usize = DEFAULT_IMMORTAL_CAPACITY,
    };

    /// Watermark saved by `enterFrame`; only the frame buffer rewinds.
    pub const FrameMark = struct { frame_len: usize };

    /// Paired with `enterFunction`; remembers whether a shadow frame was
    /// actually pushed so `leaveFunction` never pops someone else's frame.
    pub const FunctionMark = struct {
        frame: FrameMark,
        traced: bool = false,
    };

    pub fn init(opts: Options) error{OutOfMemory}!Context {
        const alloc = opts.allocator orelse std.heap.page_allocator;
        const frame = try alloc.alloc(u8, opts.frame_capacity);
        errdefer alloc.free(frame);
        const immortal = try alloc.alloc(u8, opts.immortal_capacity);
        return .{
            .allocator = alloc,
            .frame = frame,
            .immortal = immortal,
        };
    }

    pub fn deinit(self: *Context) void {
        self.deactivate();
        self.allocator.free(self.frame);
        self.allocator.free(self.immortal);
        self.* = undefined;
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
            return io.fail("Maximum call stack depth exceeded ({d} frames)", .{trace.MAX_FRAMES});
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
    pub fn enterFrame(self: *Context) FrameMark {
        return .{ .frame_len = self.frame_len };
    }

    /// Rewind the frame bump pointer on function exit. The immortal buffer is
    /// append-only for the life of the program and is never touched here.
    pub fn leaveFrame(self: *Context, mark: FrameMark) void {
        self.frame_len = mark.frame_len;
    }

    /// Bump-allocate `len` bytes with `alignment` in the frame buffer.
    pub fn allocFrame(self: *Context, len: usize, alignment: usize) error{OutOfMemory}![]u8 {
        const start = std.mem.alignForward(usize, self.frame_len, alignment);
        if (start > self.frame.len or len > self.frame.len - start) return error.OutOfMemory;
        self.frame_len = start + len;
        return self.frame[start..][0..len];
    }

    /// Bump-allocate `len` bytes with `alignment` in the immortal buffer.
    pub fn allocImmortal(self: *Context, len: usize, alignment: usize) error{OutOfMemory}![]u8 {
        const start = std.mem.alignForward(usize, self.immortal_len, alignment);
        if (start > self.immortal.len or len > self.immortal.len - start) return error.OutOfMemory;
        self.immortal_len = start + len;
        return self.immortal[start..][0..len];
    }
};

/// Process exit for emitted `main` glue (re-exported at the runtime root).
pub const exitProcess = io.exitProcess;
