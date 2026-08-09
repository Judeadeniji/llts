const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var print_ln_native: NativeFunction = undefined;

fn formatInt(buf: *[32]u8, v: Value) []const u8 {
    return switch (v) {
        .int => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "?",
        .bool => |b| if (b) "true" else "false",
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

    const ptr = try util.asPtr(args[0]);
    var msg = try util.readString(vm, ptr);
    defer vm.allocator.free(msg);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.indexOf(u8, msg, "{s}")) |_| {
            const s = try util.valueToOwnedString(vm, args[i]);
            defer vm.allocator.free(s);
            const replaced = try replaceFirst(vm.allocator, msg, "{s}", s);
            vm.allocator.free(msg);
            msg = replaced;
        } else if (std.mem.indexOf(u8, msg, "{i}")) |_| {
            var ibuf: [32]u8 = undefined;
            const s = formatInt(&ibuf, args[i]);
            const replaced = try replaceFirst(vm.allocator, msg, "{i}", s);
            vm.allocator.free(msg);
            msg = replaced;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);
    try out.appendSlice(vm.allocator, msg);
    try out.append(vm.allocator, '\n');
    _ = try std.posix.write(std.posix.STDOUT_FILENO, out.items);
    return .null;
}

pub fn register(vm: *VMState) !void {
    print_ln_native = .{ .name = "__printLn", .func = printLnFn, .arity = -1 };
    try vm.globals.put("__printLn", .{ .native = &print_ln_native });
}
