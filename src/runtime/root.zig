// LLTS Runtime — shared substrate for the bytecode VM and the native Zig backend.
//
// Both execution paths run against the same runtime primitives so that memory
// layout, frame watermarks, packed heap behaviour, and numeric semantics are
// identical between interpreted and natively compiled programs.
//
// Phase 1 stubs — filled in as native backend implementation progresses.
const std = @import("std");
const context_mod = @import("context.zig");
const ops_mod = @import("ops.zig");

pub const Context = context_mod.Context;
pub const ops = ops_mod;
