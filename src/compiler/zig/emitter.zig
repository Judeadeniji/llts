// Zig code emitter — translates analyzed LLTS AST into runtime-driving Zig source.
//
// Emission strategy (see docs/native-backend.md):
//   - Each LLTS @func → `fn lls_func_*(ctx: *rt.Context, ...) !RetType`
//   - Local variables and parameters → unboxed native Zig variables (var x: i64)
//   - Frame watermark RAII → `const mark = ctx.enterFrame(); defer ctx.leaveFrame(mark);`
//   - Control flow → native if/else, while, for, switch (not software stack dispatch)
//   - Top-level code → lls_main(ctx) initializing globals then running statements
//   - Entry wrapper → standard `pub fn main() !void` wiring allocator + lls_main
//
// Phase 2 stub — emit() returns NotImplemented until the emitter is implemented.
const std = @import("std");
const ast_mod = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const root_mod = @import("root.zig");

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    options: root_mod.EmitOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        _doc: *const ast_mod.Document,
        _state: *const state_mod.CompilerState,
        writer: std.io.AnyWriter,
        options: root_mod.EmitOptions,
    ) !Emitter {
        _ = _doc;
        _ = _state;
        return .{ .allocator = allocator, .writer = writer, .options = options };
    }

    pub fn deinit(_: *Emitter) void {}

    /// Emit a complete runtime-driving Zig compilation unit to the writer.
    /// Phase 2 implementation pending.
    pub fn emit(_: *Emitter) !void {
        return error.NotImplemented;
    }
};
