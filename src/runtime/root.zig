// LLTS Runtime — shared substrate for the bytecode VM and the native Zig backend.
//
// Both execution paths run against the same runtime primitives so that memory
// layout, frame watermarks, packed heap behaviour, and numeric semantics are
// identical between interpreted and natively compiled programs.
//
// Native traps are LLTS-owned: the runtime prints the diagnostic and the
// shadow call stack, then the emitted `main` glue exits 1. Zig never panics or
// reports an LLTS failure.
const std = @import("std");
const context_mod = @import("context.zig");
const io_mod = @import("io.zig");
const ops_mod = @import("ops.zig");
const trace_mod = @import("trace.zig");

pub const Context = context_mod.Context;
pub const context = context_mod;
pub const io = io_mod;
pub const ops = ops_mod;
pub const trace = trace_mod;

pub const ShadowStack = trace_mod.ShadowStack;
pub const Frame = trace_mod.Frame;

// Trap reporting (message + shadow stack), shared by all runtime primitives.
pub const fail = io_mod.fail;
pub const failMsg = io_mod.failMsg;
pub const exitProcess = io_mod.exitProcess;

test {
    // Keep the whole runtime tree compiling (and its tests discovered).
    std.testing.refAllDecls(@This());
    _ = @import("context.zig");
    _ = @import("io.zig");
    _ = @import("trace.zig");
}
