// Zig code emitter — entry point for the native backend.
//
// Lowers an analyzed, typed LLTS AST into a monolithic runtime-driving Zig
// source file. The emitted file @imports src/runtime/ and calls its ops
// directly, so LLVM (via zig build-exe -O ReleaseFast) can inline and
// optimize the hot paths without LLTS maintaining its own LLVM backend.
//
// See docs/native-backend.md for the full architectural rationale.
const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const emitter = @import("emitter.zig");

pub const EmitOptions = struct {
    release: bool = false,
    /// Path to the LLTS runtime root, emitted as the @import path in generated code.
    runtime_path: []const u8 = "src/runtime/root.zig",
};

pub fn emitRuntimeZig(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    state: *const state_mod.CompilerState,
    writer: anytype,
    options: EmitOptions,
) !void {
    var emit_ctx = try emitter.Emitter.init(allocator, doc, state, writer.any(), options);
    defer emit_ctx.deinit();
    try emit_ctx.emit();
}
