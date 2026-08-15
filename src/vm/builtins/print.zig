const std = @import("std");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");

const VMState = state_mod.VMState;
const Value = state_mod.Value;
const ERROR_TAG = state_mod.ERROR_TAG;

pub fn printArgs(vm: *VMState, argc: u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) try buf.append(vm.allocator, ' ');
        const distance = argc - 1 - i;
        try writeValue(vm, &buf, stack.peek(vm, distance));
    }
    try buf.append(vm.allocator, '\n');
    @import("../../io/out.zig").writeStdout(buf.items);

    var j: u8 = 0;
    while (j < argc) : (j += 1) {
        _ = stack.pop(vm);
    }
    try stack.push(vm, .null);
}

pub fn writeValue(vm: *VMState, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .null => try out.appendSlice(vm.allocator, "null"),
        .bool => |b| try out.appendSlice(vm.allocator, if (b) "true" else "false"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
            try out.appendSlice(vm.allocator, s);
        },
        .float => |n| {
            var tmp: [64]u8 = undefined;
            // Prefer integer formatting when exact (math.ceil etc. return ints; pi/e stay float)
            if (n == @floor(n) and n >= @as(f64, @floatFromInt(std.math.minInt(i32))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
                const s = try std.fmt.bufPrint(&tmp, "{d}", .{@as(i32, @intFromFloat(n))});
                try out.appendSlice(vm.allocator, s);
            } else {
                const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
                try out.appendSlice(vm.allocator, s);
            }
        },
        .name => |idx| try out.appendSlice(vm.allocator, vm.chunk.stringAt(idx)),
        .slice => |s| try out.appendSlice(vm.allocator, vm.bytes.items[s.offset..][0..s.len]),
        .bytes => |b| try writePackedBytes(vm, out, b.offset, b.len),
        .module => |m| {
            var tmp: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "<module {s}>", .{m.name});
            try out.appendSlice(vm.allocator, s);
        },
        .ptr => |p| try writePtr(vm, out, p),
        .native => |n| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "<native {s}>", .{n.name});
            try out.appendSlice(vm.allocator, s);
        },
        .function => |f| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "<fn {s}>", .{f.name});
            try out.appendSlice(vm.allocator, s);
        },
        .list => try out.appendSlice(vm.allocator, "<list>"),
        .map => try out.appendSlice(vm.allocator, "<map>"),
        .buffer => |b| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "<Buffer {d} bytes>", .{b.bytes.items.len});
            try out.appendSlice(vm.allocator, s);
        },
    }
}

fn writePackedBytes(vm: *VMState, out: *std.ArrayList(u8), offset: u32, len: u32) !void {
    const data = vm.bytes.items[offset..][0..len];
    if (len == 0) return;
    var printable = true;
    for (data) |ch| {
        if (ch < 32 or ch > 126) {
            if (ch != '\n' and ch != '\t') {
                printable = false;
                break;
            }
        }
    }
    if (printable) {
        try out.appendSlice(vm.allocator, data);
        return;
    }
    try out.append(vm.allocator, '[');
    for (data, 0..) |ch, i| {
        if (i > 0) try out.appendSlice(vm.allocator, ", ");
        var tmp: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{ch});
        try out.appendSlice(vm.allocator, s);
    }
    try out.append(vm.allocator, ']');
}

fn writePtr(vm: *VMState, out: *std.ArrayList(u8), p: i32) anyerror!void {
    if (p < 1 or !vm.isValidHeapPtr(p - 1)) {
        var tmp: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "<ptr {d}>", .{p});
        try out.appendSlice(vm.allocator, s);
        return;
    }
    const header_val = vm.slot(p - 1).*;
    if (header_val == .int and header_val.int == ERROR_TAG) {
        try out.appendSlice(vm.allocator, "Error: ");
        try writeValue(vm, out, vm.slot(p).*);
        const payload = vm.slot(p + 1).*;
        if (payload != .null) {
            try out.appendSlice(vm.allocator, " — ");
            try writeValue(vm, out, payload);
        }
        return;
    }
    if (header_val == .int and header_val.int >= 0 and header_val.int < 64 * 1024 * 1024) {
        const len: usize = @intCast(header_val.int);
        if (len == 0) return;
        var printable = true;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const val = vm.slot(p + @as(i32, @intCast(i))).*;
            if (val != .int) { printable = false; break; }
            const ch = val.int;
            if (ch < 32 or ch > 126) {
                if (ch != '\n' and ch != '\t') {
                    printable = false;
                    break;
                }
            }
        }
        if (printable) {
            i = 0;
            while (i < len) : (i += 1) {
                const ch: u8 = @intCast(vm.slot(p + @as(i32, @intCast(i))).*.int);
                try out.append(vm.allocator, ch);
            }
            return;
        }
        try out.append(vm.allocator, '[');
        i = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try out.appendSlice(vm.allocator, ", ");

            try writeValue(vm, out, vm.slot(p + @as(i32, @intCast(i))).*);
        }
        try out.append(vm.allocator, ']');
        return;
    }
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "<ptr {d}>", .{p});
    try out.appendSlice(vm.allocator, s);
}

pub const register = @import("print_reg.zig").register;
