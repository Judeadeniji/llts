const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const print_fmt = @import("print.zig");
const io_log = @import("../../io/log.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;
const ERROR_TAG = state_mod.ERROR_TAG;

var log_native: NativeFunction = undefined;
var caller_native: NativeFunction = undefined;
var caller_pc_native: NativeFunction = undefined;
var time_parts_native: NativeFunction = undefined;
var type_native: NativeFunction = undefined;
var syslog_dial_native: NativeFunction = undefined;
var hostname_native: NativeFunction = undefined;

fn parseLevel(s: []const u8) io_log.Level {
    return io_log.Level.parse(s) orelse .info;
}

fn isErrorValue(vm: *VMState, v: Value) bool {
    return vm.isErrorValue(v);
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

fn callerFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const depth: usize = if (args.len > 0) @intCast(try util.asInt(args[0])) else 0;

    // Caller 0 is the immediate caller of __caller (vm.frames[vm.frame_count - 1]).
    // Caller 1 is the caller of that function (vm.frames[vm.frame_count - 2]).
    // Caller depth is vm.frames[vm.frame_count - 1 - depth].
    if (vm.frame_count <= depth) {
        var items: [5]Value = undefined;
        items[0] = .{ .i64 = 0 };
        items[1] = try util.writeSlice(vm, "???");
        items[2] = .{ .i64 = 0 };
        items[3] = Value.fromBool(false);
        items[4] = try util.writeSlice(vm, "???");
        return try util.writeArray(vm, &items);
    }

    const idx = vm.frame_count - 1 - depth;
    const f = &vm.frames[idx];
    const file = if (f.file.len > 0) f.file else (if (vm.chunk.file.len > 0) vm.chunk.file else "???");
    const line: i64 = if (idx == vm.frame_count - 1)
        (if (vm.current_line > 0) @intCast(vm.current_line) else @intCast(f.line))
    else
        @intCast(f.line);

    try vm.pc_table.append(vm.allocator, .{
        .file = file,
        .line = @intCast(line),
        .func_name = f.func_name,
    });
    const pc: i64 = @intCast(vm.pc_table.items.len);

    var items: [5]Value = undefined;
    items[0] = .{ .i64 = pc };
    items[1] = try util.writeSlice(vm, file);
    items[2] = .{ .i64 = line };
    items[3] = Value.fromBool(true);
    items[4] = try util.writeSlice(vm, f.func_name);
    return try util.writeArray(vm, &items);
}

fn callerPCFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const pc_val = try util.asInt(args[0]);
    if (pc_val >= 1 and pc_val <= vm.pc_table.items.len) {
        const item = vm.pc_table.items[@intCast(pc_val - 1)];
        var items: [3]Value = undefined;
        items[0] = try util.writeSlice(vm, item.file);
        items[1] = .{ .i64 = @intCast(item.line) };
        items[2] = try util.writeSlice(vm, item.func_name);
        return try util.writeArray(vm, &items);
    }
    var items: [3]Value = undefined;
    items[0] = try util.writeSlice(vm, "???");
    items[1] = .{ .i64 = 0 };
    items[2] = try util.writeSlice(vm, "???");
    return try util.writeArray(vm, &items);
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timep: *const isize, result: *Tm) ?*Tm;
extern "c" fn gmtime_r(timep: *const isize, result: *Tm) ?*Tm;

fn timePartsFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const ns = try util.asInt(args[0]);
    const utc = if (args.len >= 2) args[1].isTruthy() else false;

    const sec: isize = @intCast(@divFloor(ns, 1_000_000_000));
    var rem_ns: i64 = @mod(ns, 1_000_000_000);
    if (rem_ns < 0) rem_ns += 1_000_000_000;

    var tm: Tm = undefined;
    if (utc) {
        _ = gmtime_r(&sec, &tm);
    } else {
        _ = localtime_r(&sec, &tm);
    }

    var items: [7]Value = undefined;
    items[0] = .{ .i64 = @as(i64, tm.year) + 1900 };
    items[1] = .{ .i64 = @as(i64, tm.mon) + 1 };
    items[2] = .{ .i64 = @as(i64, tm.mday) };
    items[3] = .{ .i64 = @as(i64, tm.hour) };
    items[4] = .{ .i64 = @as(i64, tm.min) };
    items[5] = .{ .i64 = @as(i64, tm.sec) };
    items[6] = .{ .i64 = rem_ns };
    return try util.writeArray(vm, &items);
}

fn typeFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const v = args[0];
    const name = switch (v) {
        .null => "nil",
        .u1 => "bool",
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => "int",
        .f32, .f64 => "float",
        .name, .slice => "string",
        .bytes => "bytes",
        .array => "array",
        .ptr => |p| blk: {
            if (vm.isValidHeapPtr(p - 1) and vm.slot(p - 1).*.i64 == ERROR_TAG) {
                break :blk "error";
            }
            break :blk "pointer";
        },
        .function, .native => "func",
        .module => "module",
        .list => "list",
        .map => "map",
        .buffer => "buffer",
    };
    return try util.writeSlice(vm, name);
}

fn hostnameFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const u = std.posix.uname();
    const nodename = std.mem.sliceTo(&u.nodename, 0);
    return try util.writeSlice(vm, nodename);
}

fn connectUnix(path: []const u8, sock_type: u32) !std.posix.fd_t {
    const fd = try std.posix.socket(std.posix.AF.UNIX, sock_type, 0);
    errdefer std.posix.close(fd);

    var addr: std.posix.sockaddr.un = .{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const addr_len = @as(std.posix.socklen_t, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1));
    try std.posix.connect(fd, @ptrCast(&addr), addr_len);
    return fd;
}

fn syslogDialFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    const network = if (args.len > 0) try util.valueToOwnedString(vm, args[0]) else try vm.allocator.dupe(u8, "");
    defer vm.allocator.free(network);
    const raddr = if (args.len > 1) try util.valueToOwnedString(vm, args[1]) else try vm.allocator.dupe(u8, "");
    defer vm.allocator.free(raddr);

    if (network.len == 0 or std.mem.eql(u8, network, "unix") or std.mem.eql(u8, network, "unixgram")) {
        if (raddr.len > 0) {
            const sock_type: u32 = if (std.mem.eql(u8, network, "unix")) std.posix.SOCK.STREAM else std.posix.SOCK.DGRAM;
            if (connectUnix(raddr, sock_type)) |fd| {
                return .{ .i64 = fd };
            } else |err| {
                return try util.makeErrorWithPayload(vm, "SyslogError", try util.writeSlice(vm, @errorName(err)));
            }
        }
        const paths = [_][]const u8{ "/dev/log", "/var/run/syslog", "/var/run/log" };
        for (paths) |p| {
            if (connectUnix(p, std.posix.SOCK.DGRAM)) |fd| {
                return .{ .i64 = fd };
            } else |_| {}
            if (connectUnix(p, std.posix.SOCK.STREAM)) |fd| {
                return .{ .i64 = fd };
            } else |_| {}
        }
        return try util.makeErrorWithPayload(vm, "SyslogError", try util.writeSlice(vm, "Unix syslog delivery error"));
    }

    if (std.mem.eql(u8, network, "udp") or std.mem.eql(u8, network, "tcp")) {
        var host: []const u8 = "127.0.0.1";
        var port_str: []const u8 = "514";
        if (std.mem.lastIndexOfScalar(u8, raddr, ':')) |colon| {
            host = raddr[0..colon];
            port_str = raddr[colon + 1 ..];
        } else if (raddr.len > 0) {
            host = raddr;
        }
        const port = std.fmt.parseInt(u16, port_str, 10) catch 514;
        const sock_type: u32 = if (std.mem.eql(u8, network, "tcp")) std.posix.SOCK.STREAM else std.posix.SOCK.DGRAM;
        const fd = std.posix.socket(std.posix.AF.INET, sock_type, 0) catch |err| {
            return try util.makeErrorWithPayload(vm, "SyslogError", try util.writeSlice(vm, @errorName(err)));
        };
        errdefer std.posix.close(fd);

        const parsed_ip = std.net.Address.parseIp4(host, port) catch {
            return try util.makeErrorWithPayload(vm, "SyslogError", try util.writeSlice(vm, "InvalidAddress"));
        };
        std.posix.connect(fd, &parsed_ip.any, parsed_ip.getOsSockLen()) catch |err| {
            return try util.makeErrorWithPayload(vm, "SyslogError", try util.writeSlice(vm, @errorName(err)));
        };
        return .{ .i64 = fd };
    }

    return try util.makeErrorWithPayload(vm, "SyslogError", try util.writeSlice(vm, "Unknown network"));
}

pub fn register(vm: *VMState) !void {
    log_native = .{
        .name = "__hostLog",
        .func = logFn,
        .arity = -1,
    };
    caller_native = .{
        .name = "__caller",
        .func = callerFn,
        .arity = -1,
    };
    caller_pc_native = .{
        .name = "__callerPC",
        .func = callerPCFn,
        .arity = 1,
    };
    time_parts_native = .{
        .name = "__timeParts",
        .func = timePartsFn,
        .arity = -1,
    };
    type_native = .{
        .name = "__type",
        .func = typeFn,
        .arity = 1,
    };
    syslog_dial_native = .{
        .name = "__syslogDial",
        .func = syslogDialFn,
        .arity = -1,
    };
    hostname_native = .{
        .name = "__hostname",
        .func = hostnameFn,
        .arity = 0,
    };

    try vm.defineGlobal("__hostLog", .{ .native = &log_native });
    try vm.defineGlobal("__caller", .{ .native = &caller_native });
    try vm.defineGlobal("__callerPC", .{ .native = &caller_pc_native });
    try vm.defineGlobal("__timeParts", .{ .native = &time_parts_native });
    try vm.defineGlobal("__type", .{ .native = &type_native });
    try vm.defineGlobal("__syslogDial", .{ .native = &syslog_dial_native });
    try vm.defineGlobal("__hostname", .{ .native = &hostname_native });
}
