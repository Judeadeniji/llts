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
var char_code_at_n: NativeFunction = undefined;

fn strlenFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    return switch (args[0]) {
        .slice => |s| .{ .int = @intCast(s.len) },
        .name => |idx| .{ .int = @intCast(vm.chunk.stringAt(idx).len) },
        .ptr => |p| .{ .int = vm.memory[@intCast(p - 1)].int },
        else => error.TypeError,
    };
}

fn substrFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    
    const start: u32 = @intCast(@max(try util.asInt(args[1]), 0));
    const len: u32 = @intCast(@max(try util.asInt(args[2]), 0));
    
    if (args[0] == .slice) {
        const s = args[0].slice;
        const bounded_start = @min(start, s.len);
        const bounded_len = @min(len, s.len - bounded_start);
        return .{ .slice = .{ .offset = s.offset + bounded_start, .len = bounded_len } };
    }
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    const bounded_start = @min(start, str.len);
    const bounded_len = @min(len, str.len - bounded_start);
    const slice = if (bounded_start >= str.len) "" else str[bounded_start..bounded_start + bounded_len];
    return try util.writeSlice(vm, slice);
}

fn indexOfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const search = try util.valueToStr(vm, args[1], &buf2);
    
    if (std.mem.indexOf(u8, str, search)) |idx| return .{ .int = @intCast(idx) };
    return .{ .int = -1 };
}

fn splitFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const sep = try util.valueToStr(vm, args[1], &buf2);

    var ptrs: std.ArrayList(Value) = .empty;
    defer ptrs.deinit(vm.allocator);

    if (sep.len == 0) {
        for (str) |ch| {
            const part = try util.writeSlice(vm, &[_]u8{ch});
            try ptrs.append(vm.allocator, part);
        }
    } else {
        var it = std.mem.splitSequence(u8, str, sep);
        while (it.next()) |part| {
            const p = try util.writeSlice(vm, part);
            try ptrs.append(vm.allocator, p);
        }
    }
    return try util.writeArray(vm, ptrs.items);
}

fn mapCase(vm: *VMState, args: []Value, upper: bool) !Value {
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, str.len);
    for (str) |c| {
        vm.string_bytes.appendAssumeCapacity(if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c));
    }
    return .{ .slice = .{ .offset = offset, .len = @intCast(str.len) } };
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
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    return try util.writeSlice(vm, std.mem.trim(u8, str, &std.ascii.whitespace));
}

fn replaceFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    var buf3: std.ArrayList(u8) = .empty; defer buf3.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const search = try util.valueToStr(vm, args[1], &buf2);
    const repl = try util.valueToStr(vm, args[2], &buf3);
    
    const out_len = std.mem.replacementSize(u8, str, search, repl);
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, out_len);
    
    const out_slice = vm.string_bytes.unusedCapacitySlice()[0..out_len];
    _ = std.mem.replace(u8, str, search, repl, out_slice);
    vm.string_bytes.items.len += out_len;
    
    return .{ .slice = .{ .offset = offset, .len = @intCast(out_len) } };
}

fn concatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const a = try util.valueToStr(vm, args[0], &buf1);
    const b = try util.valueToStr(vm, args[1], &buf2);
    
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.appendSlice(vm.allocator, a);
    try vm.string_bytes.appendSlice(vm.allocator, b);
    return .{ .slice = .{ .offset = offset, .len = @intCast(a.len + b.len) } };
}

fn repeatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    const count: usize = @intCast(@max(try util.asInt(args[1]), 0));
    
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, str.len * count);
    
    var i: usize = 0;
    while (i < count) : (i += 1) vm.string_bytes.appendSliceAssumeCapacity(str);
    
    return .{ .slice = .{ .offset = offset, .len = @intCast(str.len * count) } };
}

fn startsWithFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const prefix = try util.valueToStr(vm, args[1], &buf2);
    
    return .{ .bool = std.mem.startsWith(u8, str, prefix) };
}

fn endsWithFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const suffix = try util.valueToStr(vm, args[1], &buf2);
    
    return .{ .bool = std.mem.endsWith(u8, str, suffix) };
}

fn charCodeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const index: u32 = @intCast(@max(try util.asInt(args[1]), 0));
    
    if (args[0] == .slice) {
        const s = args[0].slice;
        if (index >= s.len) return .{ .int = -1 };
        return .{ .int = vm.string_bytes.items[s.offset + index] };
    }
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    if (index >= str.len) return .{ .int = -1 };
    return .{ .int = str[index] };
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
    char_code_at_n = .{ .name = "__charCodeAt", .func = charCodeFn, .arity = 2 };

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
    try vm.globals.put("__charCodeAt", .{ .native = &char_code_at_n });
}
