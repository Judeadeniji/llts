//! LLTS error values — native counterpart to the VM's tagged error pointers
//! (`ERROR_TAG` header + code slot + payload slot).
//!
//! Rendering parity lives in `print.zig`: `Error: <code>` with ` — <payload>`
//! appended when a payload is present (VM `writePtr` error-arm format).

const std = @import("std");

/// Aggregate payload kinds, so rendering can produce VM-exact placeholders
/// (`<map>`, `<list>`, …) before those collections exist natively.
pub const AggKind = enum { list, map, buffer, module, function, other };

pub const AggRef = struct {
    ptr: *anyopaque,
    kind: AggKind = .other,
    /// Element/byte count for `<Buffer N bytes>` rendering.
    len: usize = 0,
};

pub const Payload = union(enum) {
    none,
    int: i64,
    float: f64,
    boolean: bool,
    str: []const u8,
    agg: AggRef,
};

pub const Error = struct {
    code: []const u8,
    payload: Payload = .{ .none = {} },
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

/// Construct an error value (`error(code)` / `error(code, payload)`).
pub fn make(code: []const u8, payload: Payload) Error {
    return .{ .code = code, .payload = payload };
}

/// Construct a payload-free error (`error(code)` — VM stores null payload).
pub fn makeCode(code: []const u8) Error {
    return .{ .code = code };
}

/// Equality compares codes only, ignoring payloads (`valuesEqual` error-arm
/// parity: the VM compares the code slot and never looks at the payload).
pub fn eq(a: Error, b: Error) bool {
    return std.mem.eql(u8, a.code, b.code);
}

/// Runtime `isError` on a native error value: always true for the struct type.
/// (The emitter uses this at compile-time-driven type checks; dynamic unions
/// get a runtime op in a later phase.)
pub fn isError(e: Error) bool {
    _ = e;
    return true;
}
