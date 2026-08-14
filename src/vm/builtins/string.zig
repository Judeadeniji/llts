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
var parse_int_n: NativeFunction = undefined;
var parse_float_n: NativeFunction = undefined;
var from_char_code_n: NativeFunction = undefined;
var contains_n: NativeFunction = undefined;
var last_index_of_n: NativeFunction = undefined;
var index_of_from_n: NativeFunction = undefined;
var trim_start_n: NativeFunction = undefined;
var trim_end_n: NativeFunction = undefined;
var replace_first_n: NativeFunction = undefined;
var slice_n: NativeFunction = undefined;
var compare_n: NativeFunction = undefined;
var eql_n: NativeFunction = undefined;
var split_max_n: NativeFunction = undefined;
var join_n: NativeFunction = undefined;
var pad_start_n: NativeFunction = undefined;
var pad_end_n: NativeFunction = undefined;
var is_empty_n: NativeFunction = undefined;
var is_blank_n: NativeFunction = undefined;

fn strlenFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    return switch (args[0]) {
        .slice => |s| .{ .int = @intCast(s.len) },
        .bytes => |b| .{ .int = b.len },
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

fn containsFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const search = try util.valueToStr(vm, args[1], &buf2);
    
    return .{ .bool = std.mem.indexOf(u8, str, search) != null };
}

fn lastIndexOfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const search = try util.valueToStr(vm, args[1], &buf2);
    
    if (std.mem.lastIndexOf(u8, str, search)) |idx| return .{ .int = @intCast(idx) };
    return .{ .int = -1 };
}

fn indexOfFromFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const search = try util.valueToStr(vm, args[1], &buf2);
    const from: usize = @intCast(@max(try util.asInt(args[2]), 0));
    
    if (from >= str.len) return .{ .int = -1 };
    
    if (std.mem.indexOfPos(u8, str, from, search)) |idx| return .{ .int = @intCast(idx) };
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

const ArenaSrc = struct {
    off: ?u32,
    interned: []const u8,
    len: usize,

    fn bytes(self: ArenaSrc, vm: *VMState) []const u8 {
        if (self.off) |o| return vm.string_bytes.items[o .. o + self.len];
        return self.interned;
    }
};

fn srcOf(vm: *VMState, v: Value, buf: *std.ArrayList(u8)) !ArenaSrc {
    return switch (v) {
        .slice => |s| .{ .off = s.offset, .interned = "", .len = s.len },
        .name => |idx| blk: {
            const b = vm.chunk.stringAt(idx);
            break :blk .{ .off = null, .interned = b, .len = b.len };
        },
        .bytes => |b| .{ .off = null, .interned = vm.bytes[b.offset..][0..b.len], .len = b.len },
        .ptr => blk: {
            const b = try util.valueToStr(vm, v, buf);
            break :blk .{ .off = null, .interned = b, .len = b.len };
        },
        else => error.TypeError,
    };
}

fn mapCase(vm: *VMState, args: []Value, upper: bool) !Value {
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const src = try srcOf(vm, args[0], &buf);

    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, src.len);
    for (src.bytes(vm)) |c| {
        vm.string_bytes.appendAssumeCapacity(if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c));
    }
    return .{ .slice = .{ .offset = offset, .len = @intCast(src.len) } };
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

fn trimStartFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    return try util.writeSlice(vm, std.mem.trimLeft(u8, str, &std.ascii.whitespace));
}

fn trimEndFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    return try util.writeSlice(vm, std.mem.trimRight(u8, str, &std.ascii.whitespace));
}

fn replaceFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(vm.allocator);
    var buf3: std.ArrayList(u8) = .empty;
    defer buf3.deinit(vm.allocator);

    const str = try srcOf(vm, args[0], &buf1);
    const search = try srcOf(vm, args[1], &buf2);
    const repl = try srcOf(vm, args[2], &buf3);

    const out_len = std.mem.replacementSize(u8, str.bytes(vm), search.bytes(vm), repl.bytes(vm));
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, out_len);

    const out_slice = vm.string_bytes.unusedCapacitySlice()[0..out_len];
    _ = std.mem.replace(u8, str.bytes(vm), search.bytes(vm), repl.bytes(vm), out_slice);
    vm.string_bytes.items.len += out_len;

    return .{ .slice = .{ .offset = offset, .len = @intCast(out_len) } };
}

fn replaceFirstFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(vm.allocator);
    var buf3: std.ArrayList(u8) = .empty;
    defer buf3.deinit(vm.allocator);

    const str = try srcOf(vm, args[0], &buf1);
    const search = try srcOf(vm, args[1], &buf2);
    const repl = try srcOf(vm, args[2], &buf3);

    if (std.mem.indexOf(u8, str.bytes(vm), search.bytes(vm))) |idx| {
        const out_len = str.len - search.len + repl.len;
        const offset: u32 = @intCast(vm.string_bytes.items.len);
        try vm.string_bytes.ensureUnusedCapacity(vm.allocator, out_len);

        const s = str.bytes(vm);
        vm.string_bytes.appendSliceAssumeCapacity(s[0..idx]);
        vm.string_bytes.appendSliceAssumeCapacity(repl.bytes(vm));
        vm.string_bytes.appendSliceAssumeCapacity(s[idx + search.len ..]);

        return .{ .slice = .{ .offset = offset, .len = @intCast(out_len) } };
    }
    return try util.writeSlice(vm, str.bytes(vm));
}

fn concatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try util.appendStr(vm, args[0]);
    try util.appendStr(vm, args[1]);
    return .{ .slice = .{ .offset = offset, .len = @intCast(vm.string_bytes.items.len - offset) } };
}

fn repeatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);
    const src = try srcOf(vm, args[0], &buf);
    const count: usize = @intCast(@max(try util.asInt(args[1]), 0));

    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, src.len * count);

    var i: usize = 0;
    while (i < count) : (i += 1) vm.string_bytes.appendSliceAssumeCapacity(src.bytes(vm));

    return .{ .slice = .{ .offset = offset, .len = @intCast(src.len * count) } };
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

fn parseIntFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    const base: u8 = if (args.len > 1) @intCast(@max(try util.asInt(args[1]), 2)) else 10;
    
    // allow negative sign
    const val = std.fmt.parseInt(i64, str, base) catch return .{ .int = 0 }; // or error?
    return .{ .int = val };
}

fn parseFloatFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    const val = std.fmt.parseFloat(f64, str) catch return .{ .float = std.math.nan(f64) };
    return .{ .float = val };
}

fn fromCharCodeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const code = try util.asInt(args[0]);
    
    if (code < 0 or code > 255) return try util.makeErrorWithPayload(vm, "InvalidCharCode", .{ .int = code });
    var buf: [1]u8 = .{ @intCast(code) };
    return try util.writeSlice(vm, &buf);
}

fn sliceFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    
    const str_len: i64 = @intCast(str.len);
    
    var start_idx = try util.asInt(args[1]);
    if (start_idx < 0) {
        start_idx = @max(str_len + start_idx, 0);
    } else {
        start_idx = @min(start_idx, str_len);
    }
    
    var end_idx = str_len;
    if (args.len > 2) {
        end_idx = try util.asInt(args[2]);
        if (end_idx < 0) {
            end_idx = @max(str_len + end_idx, 0);
        } else {
            end_idx = @min(end_idx, str_len);
        }
    }
    
    if (start_idx >= end_idx) return try util.writeSlice(vm, "");
    
    const start: usize = @intCast(start_idx);
    const end: usize = @intCast(end_idx);
    
    if (args[0] == .slice) {
        const s = args[0].slice;
        return .{ .slice = .{ .offset = s.offset + @as(u32, @intCast(start)), .len = @as(u32, @intCast(end - start)) } };
    }
    return try util.writeSlice(vm, str[start..end]);
}

fn compareFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const a = try util.valueToStr(vm, args[0], &buf1);
    const b = try util.valueToStr(vm, args[1], &buf2);
    
    const order = std.mem.order(u8, a, b);
    return switch (order) {
        .lt => .{ .int = -1 },
        .eq => .{ .int = 0 },
        .gt => .{ .int = 1 },
    };
}

fn eqlFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;
    return .{ .bool = util.stringEquals(vm, args[0], args[1]) };
}

fn splitMaxFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;
    
    var buf1: std.ArrayList(u8) = .empty; defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty; defer buf2.deinit(vm.allocator);
    
    const str = try util.valueToStr(vm, args[0], &buf1);
    const sep = try util.valueToStr(vm, args[1], &buf2);
    const limit = @max(try util.asInt(args[2]), 0);
    
    var ptrs: std.ArrayList(Value) = .empty;
    defer ptrs.deinit(vm.allocator);

    if (limit == 0) {
        return try util.writeArray(vm, ptrs.items);
    }
    
    if (sep.len == 0) {
        var count: i64 = 0;
        var i: usize = 0;
        while (i < str.len and count < limit - 1) : (i += 1) {
            const part = try util.writeSlice(vm, &[_]u8{str[i]});
            try ptrs.append(vm.allocator, part);
            count += 1;
        }
        const rest = try util.writeSlice(vm, str[i..]);
        try ptrs.append(vm.allocator, rest);
    } else {
        var count: i64 = 0;
        var start: usize = 0;
        while (count < limit - 1) {
            if (std.mem.indexOfPos(u8, str, start, sep)) |idx| {
                const part = str[start..idx];
                const p = try util.writeSlice(vm, part);
                try ptrs.append(vm.allocator, p);
                start = idx + sep.len;
                count += 1;
            } else {
                break;
            }
        }
        const rest = str[start..];
        const p = try util.writeSlice(vm, rest);
        try ptrs.append(vm.allocator, p);
    }
    return try util.writeArray(vm, ptrs.items);
}

fn joinFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;

    const offset: u32 = @intCast(vm.string_bytes.items.len);

    switch (args[0]) {
        .ptr => |arr_ptr| {
            const array_len: usize = @intCast(vm.memory[@intCast(arr_ptr - 1)].int);
            var i: usize = 0;
            while (i < array_len) : (i += 1) {
                const item_val = vm.memory[@intCast(arr_ptr + @as(i32, @intCast(i)))];
                try util.appendStr(vm, item_val);
                if (i + 1 < array_len) try util.appendStr(vm, args[1]);
            }
        },
        .list => |lst| {
            const items = lst.items.items;
            for (items, 0..) |item_val, i| {
                try util.appendStr(vm, item_val);
                if (i + 1 < items.len) try util.appendStr(vm, args[1]);
            }
        },
        else => return error.TypeError,
    }

    return .{ .slice = .{ .offset = offset, .len = @intCast(vm.string_bytes.items.len - offset) } };
}

fn padStartFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;

    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(vm.allocator);

    const str = try srcOf(vm, args[0], &buf1);
    const target_len: usize = @intCast(@max(try util.asInt(args[1]), 0));
    const pad = try srcOf(vm, args[2], &buf2);

    if (str.len >= target_len or pad.len == 0) return try util.writeSlice(vm, str.bytes(vm));

    const pad_needed = target_len - str.len;
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, target_len);

    var written: usize = 0;
    while (written < pad_needed) {
        const take = @min(pad.len, pad_needed - written);
        vm.string_bytes.appendSliceAssumeCapacity(pad.bytes(vm)[0..take]);
        written += take;
    }
    vm.string_bytes.appendSliceAssumeCapacity(str.bytes(vm));

    return .{ .slice = .{ .offset = offset, .len = @intCast(target_len) } };
}

fn padEndFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 3) return error.ArityError;

    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(vm.allocator);
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(vm.allocator);

    const str = try srcOf(vm, args[0], &buf1);
    const target_len: usize = @intCast(@max(try util.asInt(args[1]), 0));
    const pad = try srcOf(vm, args[2], &buf2);

    if (str.len >= target_len or pad.len == 0) return try util.writeSlice(vm, str.bytes(vm));

    const pad_needed = target_len - str.len;
    const offset: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.ensureUnusedCapacity(vm.allocator, target_len);

    vm.string_bytes.appendSliceAssumeCapacity(str.bytes(vm));
    var written: usize = 0;
    while (written < pad_needed) {
        const take = @min(pad.len, pad_needed - written);
        vm.string_bytes.appendSliceAssumeCapacity(pad.bytes(vm)[0..take]);
        written += take;
    }

    return .{ .slice = .{ .offset = offset, .len = @intCast(target_len) } };
}

fn isEmptyFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    
    if (args[0] == .slice) {
        return .{ .bool = args[0].slice.len == 0 };
    }
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    return .{ .bool = str.len == 0 };
}

fn isBlankFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);
    const trimmed = std.mem.trim(u8, str, &std.ascii.whitespace);
    return .{ .bool = trimmed.len == 0 };
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
    parse_int_n = .{ .name = "__parseInt", .func = parseIntFn, .arity = 2 };
    parse_float_n = .{ .name = "__parseFloat", .func = parseFloatFn, .arity = 1 };
    from_char_code_n = .{ .name = "__fromCharCode", .func = fromCharCodeFn, .arity = 1 };

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
    try vm.globals.put("__parseInt", .{ .native = &parse_int_n });
    try vm.globals.put("__parseFloat", .{ .native = &parse_float_n });
    try vm.globals.put("__fromCharCode", .{ .native = &from_char_code_n });
    
    contains_n = .{ .name = "__contains", .func = containsFn, .arity = 2 };
    last_index_of_n = .{ .name = "__lastIndexOf", .func = lastIndexOfFn, .arity = 2 };
    index_of_from_n = .{ .name = "__indexOfFrom", .func = indexOfFromFn, .arity = 3 };
    trim_start_n = .{ .name = "__trimStart", .func = trimStartFn, .arity = 1 };
    trim_end_n = .{ .name = "__trimEnd", .func = trimEndFn, .arity = 1 };
    replace_first_n = .{ .name = "__replaceFirst", .func = replaceFirstFn, .arity = 3 };
    slice_n = .{ .name = "__slice", .func = sliceFn, .arity = 3 };
    compare_n = .{ .name = "__compare", .func = compareFn, .arity = 2 };
    eql_n = .{ .name = "__eql", .func = eqlFn, .arity = 2 };
    split_max_n = .{ .name = "__splitMax", .func = splitMaxFn, .arity = 3 };
    join_n = .{ .name = "__join", .func = joinFn, .arity = 2 };
    pad_start_n = .{ .name = "__padStart", .func = padStartFn, .arity = 3 };
    pad_end_n = .{ .name = "__padEnd", .func = padEndFn, .arity = 3 };
    is_empty_n = .{ .name = "__isEmpty", .func = isEmptyFn, .arity = 1 };
    is_blank_n = .{ .name = "__isBlank", .func = isBlankFn, .arity = 1 };

    try vm.globals.put("__contains", .{ .native = &contains_n });
    try vm.globals.put("__lastIndexOf", .{ .native = &last_index_of_n });
    try vm.globals.put("__indexOfFrom", .{ .native = &index_of_from_n });
    try vm.globals.put("__trimStart", .{ .native = &trim_start_n });
    try vm.globals.put("__trimEnd", .{ .native = &trim_end_n });
    try vm.globals.put("__replaceFirst", .{ .native = &replace_first_n });
    try vm.globals.put("__slice", .{ .native = &slice_n });
    try vm.globals.put("__compare", .{ .native = &compare_n });
    try vm.globals.put("__eql", .{ .native = &eql_n });
    try vm.globals.put("__splitMax", .{ .native = &split_max_n });
    try vm.globals.put("__join", .{ .native = &join_n });
    try vm.globals.put("__padStart", .{ .native = &pad_start_n });
    try vm.globals.put("__padEnd", .{ .native = &pad_end_n });
    try vm.globals.put("__isEmpty", .{ .native = &is_empty_n });
    try vm.globals.put("__isBlank", .{ .native = &is_blank_n });
}
