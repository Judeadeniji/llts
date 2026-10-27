//! LLTS Runtime — native support library for emitted Zig code.
//!
//! Typed Zig API only: no `Value`, no `VMState`, no dispatch tables. The
//! bytecode VM keeps its own copy paths (`src/vm/**`); both share the width
//! table (`widths.zig`, re-exported by `src/compiler/widths.zig`) so numeric
//! semantics cannot drift.
//!
//! Substrates:
//!   * `context` — two-buffer bump heap (frame + immortal) with fixed
//!     capacity and stable pointers, plus the LLTS shadow call stack.
//!   * `mem`     — allocation/clone/concat primitives (VM heap builtins).
//!   * `arith`   — arithmetic/bitwise/comparison ops with VM-exact traps.
//!   * `err`     — LLTS error values (`error(code, payload)`).
//!   * `print`   — VM-parity value formatting and `print(...)`.
//!   * `io`      — minimal fd writes + trap reporting + process exit.
//!   * `trace`   — shadow-stack frames and VM-parity trace formatting.
//!
//! Native traps are LLTS-owned: the runtime prints the diagnostic and the
//! shadow call stack, then the emitted `main` glue exits 1. Zig never panics
//! or reports an LLTS failure.
const std = @import("std");

const context_mod = @import("context.zig");
const io_mod = @import("io.zig");
const mem_mod = @import("mem.zig");
const arith_mod = @import("arith.zig");
const err_mod = @import("err.zig");
const print_mod = @import("print.zig");
const widths_mod = @import("widths.zig");
const trace_mod = @import("trace.zig");

pub const Context = context_mod.Context;
pub const FrameMark = context_mod.Context.FrameMark;
pub const FunctionMark = context_mod.Context.FunctionMark;
pub const context = context_mod;
pub const io = io_mod;
pub const mem = mem_mod;
pub const arith = arith_mod;
pub const err = err_mod;
pub const print = print_mod;
pub const widths = widths_mod;
pub const trace = trace_mod;

pub const Width = widths_mod.Width;

// Error values.
pub const Error = err_mod.Error;
pub const Payload = err_mod.Payload;

// Shadow-stack diagnostics.
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
    _ = @import("mem.zig");
    _ = @import("arith.zig");
    _ = @import("err.zig");
    _ = @import("print.zig");
    _ = @import("widths.zig");
    _ = @import("trace.zig");
}
