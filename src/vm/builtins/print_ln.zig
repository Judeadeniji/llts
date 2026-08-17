const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");
const widths = @import("../../compiler/widths.zig");
const out_mod = @import("../../io/out.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var print_ln_native: NativeFunction = undefined;

fn formatInt(buf: *[32]u8, v: Value) []const u8 {
    if (widths.valueAsI64(v)) |n| {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    }
    return switch (v) {
        .u1 => |b| if (b != 0) "true" else "false",
        .null => "null",
        .ptr => |p| std.fmt.bufPrint(buf, "{d}", .{p}) catch "?",
        else => "?",
    };
}

fn replaceFirst(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, haystack, needle)) |idx| {
        return try std.mem.concat(allocator, u8, &.{
            haystack[0..idx],
            replacement,
            haystack[idx + needle.len ..],
        });
    }
    return try allocator.dupe(u8, haystack);
}

fn printLnFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;

    var msg = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(msg);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const idx_s = std.mem.indexOf(u8, msg, "{s}");
        const idx_i = std.mem.indexOf(u8, msg, "{i}");
        const idx_c = std.mem.indexOf(u8, msg, "{c}");

        var min_idx: ?usize = null;
        var placeholder: enum { s, i, c } = .s;

        if (idx_s) |pos| { min_idx = pos; placeholder = .s; }
        if (idx_i) |pos| {
            if (min_idx == null or pos < min_idx.?) { min_idx = pos; placeholder = .i; }
        }
        if (idx_c) |pos| {
            if (min_idx == null or pos < min_idx.?) { min_idx = pos; placeholder = .c; }
        }

        if (min_idx == null) break;

        switch (placeholder) {
            .s => {
                const s = try util.valueToOwnedString(vm, args[i]);
                defer vm.allocator.free(s);
                const replaced = try replaceFirst(vm.allocator, msg, "{s}", s);
                vm.allocator.free(msg);
                msg = replaced;
            },
            .i => {
                var ibuf: [32]u8 = undefined;
                const s = formatInt(&ibuf, args[i]);
                const replaced = try replaceFirst(vm.allocator, msg, "{i}", s);
                vm.allocator.free(msg);
                msg = replaced;
            },
            .c => {
                var cbuf: [1]u8 = undefined;
                if (args[i] == .u8) {
                    cbuf[0] = args[i].u8;
                } else if (widths.valueAsI64(args[i])) |n| {
                    cbuf[0] = @intCast(n);
                } else {
                    cbuf[0] = '?';
                }
                const replaced = try replaceFirst(vm.allocator, msg, "{c}", &cbuf);
                vm.allocator.free(msg);
                msg = replaced;
            },
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);
    try out.appendSlice(vm.allocator, msg);
    try out.append(vm.allocator, '\n');
    out_mod.writeStdout(out.items);
    return .null;
}

pub fn register(vm: *VMState) !void {
    print_ln_native = .{ .name = "__printLn", .func = printLnFn, .arity = -1 };
    try vm.defineGlobal("__printLn", .{ .native = &print_ln_native });
}
