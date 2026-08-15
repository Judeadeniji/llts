const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const print_fmt = @import("print.zig");
const io_log = @import("../../io/log.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;
const ERROR_TAG = state_mod.ERROR_TAG;

var log_native: NativeFunction = undefined;

fn parseLevel(s: []const u8) io_log.Level {
    return io_log.Level.parse(s) orelse .info;
}

fn isErrorValue(vm: *VMState, v: Value) bool {
    if (v != .ptr) return false;
    const p = v.ptr;
    if (p < 1 or !vm.isValidHeapPtr(p - 1)) return false;
    const tag = vm.slot(p - 1).*;
    return tag == .int and tag.int == ERROR_TAG;
}

/// Format an LLTS error for host logs (no redundant `Error:` prefix).
fn writeErrorArg(vm: *VMState, out: *std.ArrayList(u8), p: i32) !void {
    try print_fmt.writeValue(vm, out, vm.slot(p).*);
    const payload = vm.slot(p + 1).*;
    if (payload != .null) {
        try out.appendSlice(vm.allocator, " — ");
        try print_fmt.writeValue(vm, out, payload);
    }
}

fn writeLogArg(vm: *VMState, out: *std.ArrayList(u8), v: Value) !void {
    if (isErrorValue(vm, v)) {
        try writeErrorArg(vm, out, v.ptr);
        return;
    }
    try print_fmt.writeValue(vm, out, v);
}

fn logFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;

    var level_buf: std.ArrayList(u8) = .empty;
    defer level_buf.deinit(vm.allocator);
    try print_fmt.writeValue(vm, &level_buf, args[0]);
    const level = parseLevel(level_buf.items);

    // debug.err(errorValue): prefer structured lines over `ERROR: Error: …`
    if (level == .err and args.len == 2 and isErrorValue(vm, args[1])) {
        const p = args[1].ptr;
        var code_buf: std.ArrayList(u8) = .empty;
        defer code_buf.deinit(vm.allocator);
        try print_fmt.writeValue(vm, &code_buf, vm.slot(p).*);

        const payload = vm.slot(p + 1).*;
        if (payload == .null) {
            io_log.log(.err, "llts", "{s}", .{code_buf.items});
        } else {
            var pay_buf: std.ArrayList(u8) = .empty;
            defer pay_buf.deinit(vm.allocator);
            try print_fmt.writeValue(vm, &pay_buf, payload);
            io_log.log(.err, "llts", "{s}\n  payload: {s}", .{ code_buf.items, pay_buf.items });
        }
        return .null;
    }

    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(vm.allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (i > 1) try msg_buf.append(vm.allocator, ' ');
        try writeLogArg(vm, &msg_buf, args[i]);
    }

    io_log.log(level, "llts", "{s}", .{msg_buf.items});
    return .null;
}

pub fn register(vm: *VMState) !void {
    log_native = .{
        .name = "__hostLog",
        .func = logFn,
        .arity = -1,
    };
    try vm.defineGlobal("__hostLog", .{ .native = &log_native });
}
