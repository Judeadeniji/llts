// Stub — LLVM backend not on this branch.
const std = @import("std");
const state_mod = @import("../../compiler/state.zig");
const ast = @import("../../ast/root.zig");

pub const LlvmContext = struct {
    pub fn init(_allocator: std.mem.Allocator, _path: []const u8, _state: *const state_mod.CompilerState) @This() {
        _ = _allocator;
        _ = _path;
        _ = _state;
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn verify(_: *@This()) !void {}
    pub fn writeIr(_: *@This(), _: []const u8) !void {}
    pub fn writeBitcode(_: *@This(), _: []const u8) !void {}
};

pub fn codegen(_lc: *LlvmContext, _doc: *const ast.Document) !void {
    _ = _lc;
    _ = _doc;
    return error.NotImplemented;
}
