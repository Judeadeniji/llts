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
    _ = try std.posix.write(std.posix.STDOUT_FILENO, buf.items);

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
            // Heap loads are untyped i32s (TS parity). Interpret in-range ints as ptrs.
            if (n >= state_mod.HEAP_START and n < vm.heap_ptr) {
                try writePtr(vm, out, n);
            } else {
                var tmp: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
                try out.appendSlice(vm.allocator, s);
            }
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
    }
}

fn writePtr(vm: *VMState, out: *std.ArrayList(u8), p: i32) !void {
    // Empty strings allocate only a length header at `p-1`; data ptr may equal heap_ptr.
    if (p < 1 or p - 1 >= vm.heap_ptr) {
        var tmp: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "<ptr {d}>", .{p});
        try out.appendSlice(vm.allocator, s);
        return;
    }
    const header = vm.memory[@intCast(p - 1)];
    if (header == ERROR_TAG) {
        // Match TS: `Error: {msg}` (including empty message → `Error: `)
        try out.appendSlice(vm.allocator, "Error: ");
        try writePtr(vm, out, vm.memory[@intCast(p)]);
        return;
    }
    if (header >= 0 and header < 1024 * 1024) {
        const len: usize = @intCast(header);
        // length === 0 is an empty string allocation (TS parity)
        if (len == 0) return;
        var printable = true;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const ch = vm.memory[@intCast(p + @as(i32, @intCast(i)))];
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
                const ch: u8 = @intCast(vm.memory[@intCast(p + @as(i32, @intCast(i)))]);
                try out.append(vm.allocator, ch);
            }
            return;
        }
        try out.append(vm.allocator, '[');
        i = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try out.appendSlice(vm.allocator, ", ");
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{vm.memory[@intCast(p + @as(i32, @intCast(i)))]});
            try out.appendSlice(vm.allocator, s);
        }
        try out.append(vm.allocator, ']');
        return;
    }
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "<ptr {d}>", .{p});
    try out.appendSlice(vm.allocator, s);
}

pub const register = @import("print_reg.zig").register;
