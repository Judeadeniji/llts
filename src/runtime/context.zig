// Execution context — call stack, packed byte heap, frame watermarks, globals.
//
// In the VM this is spread across VMState; here it will be unified into a
// single struct that both the interpreter and emitted native Zig functions
// share unchanged.
//
// Phase 1 stub — implementation pending extraction from vm/state.zig.
const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Context) void {}

    /// Save the current frame watermark before entering a new call frame.
    pub fn enterFrame(_: *Context) usize {
        return 0;
    }

    /// Rewind the heap bump pointer to the saved watermark on function exit.
    pub fn leaveFrame(_: *Context, _: usize) void {}
};
