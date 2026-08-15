const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var json_parse_n: NativeFunction = undefined;
var json_stringify_n: NativeFunction = undefined;

fn parseJsonNode(vm: *VMState, val: std.json.Value) anyerror!Value {
    switch (val) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .int = @intCast(i) },
        .float => |f| return .{ .float = f },
        .string => |s| return try util.writeSlice(vm, s),
        .array => |arr| {
            var items = try vm.allocator.alloc(Value, arr.items.len);
            defer vm.allocator.free(items);
            for (arr.items, 0..) |item, i| {
                items[i] = try parseJsonNode(vm, item);
            }
            return try util.writeArray(vm, items);
        },
        .object => |obj| {
            const mod = try vm.allocModule("JSONObject");
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = try vm.allocator.dupe(u8, entry.key_ptr.*);
                const v = try parseJsonNode(vm, entry.value_ptr.*);
                try mod.props.put(k, v);
            }
            return .{ .module = mod };
        },
        else => return error.TypeError,
    }
}

fn jsonParseFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    var buf: std.ArrayList(u8) = .empty; defer buf.deinit(vm.allocator);
    const str = try util.valueToStr(vm, args[0], &buf);

    var parsed = std.json.parseFromSlice(std.json.Value, vm.allocator, str, .{}) catch |err| {
        return try util.makeErrorWithPayload(vm, "JsonError", try util.writeSlice(vm, @errorName(err)));
    };
    defer parsed.deinit();

    return try parseJsonNode(vm, parsed.value);
}

fn stringifyNode(vm: *VMState, val: Value, out: *std.io.Writer.Allocating) !void {
    switch (val) {
        .null => try out.writer.writeAll("null"),
        .bool => |b| try out.writer.print("{}", .{b}),
        .int => |i| try out.writer.print("{d}", .{i}),
        .float => |f| try out.writer.print("{d}", .{f}),
        .name => |idx| try out.writer.print("{f}", .{std.json.fmt(vm.chunk.stringAt(idx), .{})}),
        .slice => |s| try out.writer.print("{f}", .{std.json.fmt(vm.string_bytes.items[s.offset .. s.offset + s.len], .{})}),
        .bytes => |b| try out.writer.print("{f}", .{std.json.fmt(vm.bytes.items[b.offset..][0..b.len], .{})}),
        .module => |mod| {
            try out.writer.writeAll("{");
            var it = mod.props.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.writer.writeAll(",");
                try out.writer.print("{f}", .{std.json.fmt(entry.key_ptr.*, .{})});
                try out.writer.writeAll(":");
                try stringifyNode(vm, entry.value_ptr.*, out);
                first = false;
            }
            try out.writer.writeAll("}");
        },
        .ptr => |p| {
            const tag = vm.slot(p - 1).*;
            if (tag == .int and tag.int == state_mod.ERROR_TAG) {
                try out.writer.writeAll("\"[Error]\"");
                return;
            }
            const len: usize = @intCast(tag.int);
            try out.writer.writeAll("[");
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (i > 0) try out.writer.writeAll(",");
                try stringifyNode(vm, vm.slot(p + @as(i32, @intCast(i))).*, out);
            }
            try out.writer.writeAll("]");
        },
        .list => |lst| {
            try out.writer.writeAll("[");
            for (lst.items.items, 0..) |item, i| {
                if (i > 0) try out.writer.writeAll(",");
                try stringifyNode(vm, item, out);
            }
            try out.writer.writeAll("]");
        },
        .map => |mp| {
            try out.writer.writeAll("{");
            var it = mp.entries.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.writer.writeAll(",");
                try out.writer.print("{f}", .{std.json.fmt(entry.key_ptr.*, .{})});
                try out.writer.writeAll(":");
                try stringifyNode(vm, entry.value_ptr.*, out);
                first = false;
            }
            try out.writer.writeAll("}");
        },
        else => try out.writer.writeAll("\"[Object]\""),
    }
}

fn jsonStringifyFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    
    var out: std.io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    
    stringifyNode(vm, args[0], &out) catch |err| {
        return try util.makeErrorWithPayload(vm, "JsonError", try util.writeSlice(vm, @errorName(err)));
    };
    
    return try util.writeSlice(vm, out.written());
}

pub fn register(vm: *VMState) !void {
    json_parse_n = .{ .name = "__jsonParse", .func = jsonParseFn, .arity = 1 };
    json_stringify_n = .{ .name = "__jsonStringify", .func = jsonStringifyFn, .arity = 1 };
    
    try vm.defineGlobal("__jsonParse", .{ .native = &json_parse_n });
    try vm.defineGlobal("__jsonStringify", .{ .native = &json_stringify_n });
}
