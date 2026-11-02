//! LLTS error values — native counterpart to the VM's tagged error pointers
//! (`ERROR_TAG` header + message slot). Errors carry a single message string
//! and nothing else; callers that need structured data wrap the error themselves.
//!
//! Rendering parity lives in `print.zig`: `Error: <message>`.

const std = @import("std");

pub const Error = struct {
    message: []const u8,
};

/// Success-or-error value used for native error unions (`T | error`).
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Error,
    };
}

/// Runtime error extraction after `@isError` narrowing.
pub fn expectError(value: anytype) Error {
    return switch (value) {
        .ok => @panic("expected an error value"),
        .err => |e| e,
    };
}

/// Construct an error value (`error(message)`).
pub fn make(message: []const u8) Error {
    return .{ .message = message };
}

/// Equality compares messages (`valuesEqual` error-arm parity).
pub fn eq(a: Error, b: Error) bool {
    return std.mem.eql(u8, a.message, b.message);
}

/// Runtime `isError` on a native error value: always true for the struct type.
/// (The emitter uses this at compile-time-driven type checks; dynamic unions
/// get a runtime op in a later phase.)
pub fn isError(e: Error) bool {
    _ = e;
    return true;
}
