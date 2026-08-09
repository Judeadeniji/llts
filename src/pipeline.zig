const std = @import("std");
const scanner = @import("scanner/root.zig");
const parser = @import("parser/root.zig");
const compiler = @import("compiler/root.zig");
const vm_state = @import("vm/state.zig");
const execute = @import("vm/execute/root.zig");
const builtins = @import("vm/builtins/root.zig");

pub const RunOptions = struct {
    debug: bool = true,
};

pub fn runSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !void {
    var scan_result = try scanner.scan(allocator, source, path);
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source);
    defer doc.deinit();

    var chunk = try compiler.compile(allocator, &doc, .{ .debug = options.debug });
    defer chunk.deinit();

    var state = try vm_state.VMState.init(allocator, &chunk);
    defer state.deinit();
    try builtins.registerBuiltins(&state);
    try execute.execute(&state, 0);
}
