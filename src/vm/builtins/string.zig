const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var strlen_n: NativeFunction = undefined;
var substr_n: NativeFunction = undefined;
var index_of_n: NativeFunction = undefined;
var split_n: NativeFunction = undefined;
var to_upper_n: NativeFunction = undefined;
var to_lower_n: NativeFunction = undefined;
var trim_n: NativeFunction = undefined;
var replace_n: NativeFunction = undefined;
var concat_n: NativeFunction = undefined;
var repeat_n: NativeFunction = undefined;
var starts_with_n: NativeFunction = undefined;
var ends_with_n: NativeFunction = undefined;

fn strlenFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const ptr = try util.asPtr(args[0]);
    return .{ .int = vm.memory[@intCast(ptr - 1)] };
}

fn substrFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const start: usize = @intCast(@max(try util.asInt(args[1]), 0));
    const len: usize = @intCast(@max(try util.asInt(args[2]), 0));
    const end = @min(start + len, str.len);
    const slice = if (start >= str.len) "" else str[start..end];
    return try util.writeString(vm, slice);
}

fn indexOfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const search = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(search);
    if (std.mem.indexOf(u8, str, search)) |idx| return .{ .int = @intCast(idx) };
    return .{ .int = -1 };
}

fn splitFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const sep = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(sep);

    var ptrs: std.ArrayList(i32) = .empty;
    defer ptrs.deinit(vm.allocator);

    if (sep.len == 0) {
        for (str) |ch| {
            const part = try util.writeString(vm, &[_]u8{ch});
            try ptrs.append(vm.allocator, part.ptr);
        }
    } else {
        var it = std.mem.splitSequence(u8, str, sep);
        while (it.next()) |part| {
            const p = try util.writeString(vm, part);
            try ptrs.append(vm.allocator, p.ptr);
        }
    }
    return try util.writeArray(vm, ptrs.items);
}

fn mapCase(vm: *VMState, args: []Value, upper: bool) !Value {
    if (args.len < 1) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    for (str) |*c| {
        c.* = if (upper) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    }
    return try util.writeString(vm, str);
}

fn toUpperFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    return try mapCase(@ptrCast(@alignCast(vm_ptr)), args, true);
}

fn toLowerFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    return try mapCase(@ptrCast(@alignCast(vm_ptr)), args, false);
}

fn trimFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    return try util.writeString(vm, std.mem.trim(u8, str, &std.ascii.whitespace));
}

fn replaceFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const search = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(search);
    const repl = try util.valueToOwnedString(vm, args[2]);
    defer vm.allocator.free(repl);
    const out = try std.mem.replaceOwned(u8, vm.allocator, str, search, repl);
    defer vm.allocator.free(out);
    return try util.writeString(vm, out);
}

fn concatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const a = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(a);
    const b = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(b);
    const out = try std.mem.concat(vm.allocator, u8, &.{ a, b });
    defer vm.allocator.free(out);
    return try util.writeString(vm, out);
}

fn repeatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const count: usize = @intCast(@max(try util.asInt(args[1]), 0));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);
    try out.ensureTotalCapacity(vm.allocator, str.len * count);
    var i: usize = 0;
    while (i < count) : (i += 1) try out.appendSlice(vm.allocator, str);
    return try util.writeString(vm, out.items);
}

fn startsWithFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const prefix = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(prefix);
    return .{ .bool = std.mem.startsWith(u8, str, prefix) };
}

fn endsWithFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const str = try util.valueToOwnedString(vm, args[0]);
    defer vm.allocator.free(str);
    const suffix = try util.valueToOwnedString(vm, args[1]);
    defer vm.allocator.free(suffix);
    return .{ .bool = std.mem.endsWith(u8, str, suffix) };
}

pub fn register(vm: *VMState) !void {
    strlen_n = .{ .name = "__strlen", .func = strlenFn, .arity = 1 };
    substr_n = .{ .name = "__substr", .func = substrFn, .arity = 3 };
    index_of_n = .{ .name = "__indexOf", .func = indexOfFn, .arity = 2 };
    split_n = .{ .name = "__split", .func = splitFn, .arity = 2 };
    to_upper_n = .{ .name = "__toUpper", .func = toUpperFn, .arity = 1 };
    to_lower_n = .{ .name = "__toLower", .func = toLowerFn, .arity = 1 };
    trim_n = .{ .name = "__trim", .func = trimFn, .arity = 1 };
    replace_n = .{ .name = "__replace", .func = replaceFn, .arity = 3 };
    concat_n = .{ .name = "__concat", .func = concatFn, .arity = 2 };
    repeat_n = .{ .name = "__repeat", .func = repeatFn, .arity = 2 };
    starts_with_n = .{ .name = "__startsWith", .func = startsWithFn, .arity = 2 };
    ends_with_n = .{ .name = "__endsWith", .func = endsWithFn, .arity = 2 };

    try vm.globals.put("__strlen", .{ .native = &strlen_n });
    try vm.globals.put("__substr", .{ .native = &substr_n });
    try vm.globals.put("__indexOf", .{ .native = &index_of_n });
    try vm.globals.put("__split", .{ .native = &split_n });
    try vm.globals.put("__toUpper", .{ .native = &to_upper_n });
    try vm.globals.put("__toLower", .{ .native = &to_lower_n });
    try vm.globals.put("__trim", .{ .native = &trim_n });
    try vm.globals.put("__replace", .{ .native = &replace_n });
    try vm.globals.put("__concat", .{ .native = &concat_n });
    try vm.globals.put("__repeat", .{ .native = &repeat_n });
    try vm.globals.put("__startsWith", .{ .native = &starts_with_n });
    try vm.globals.put("__endsWith", .{ .native = &ends_with_n });
}
