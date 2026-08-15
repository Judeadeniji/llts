const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;

var fetch_n: NativeFunction = undefined;

fn fetchFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;

    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(vm.allocator);
    const url = try util.valueToStr(vm, args[0], &buf1);

    var method: std.http.Method = .GET;
    if (args.len > 1 and args[1] != .null) {
        var mbuf: std.ArrayList(u8) = .empty;
        defer mbuf.deinit(vm.allocator);
        const mstr = try util.valueToStr(vm, args[1], &mbuf);
        if (std.mem.eql(u8, mstr, "POST")) method = .POST
        else if (std.mem.eql(u8, mstr, "PUT")) method = .PUT
        else if (std.mem.eql(u8, mstr, "DELETE")) method = .DELETE
        else if (std.mem.eql(u8, mstr, "PATCH")) method = .PATCH;
    }

    var body_str: ?[]const u8 = null;
    var bbuf: std.ArrayList(u8) = .empty;
    defer bbuf.deinit(vm.allocator);
    if (args.len > 2 and args[2] != .null) {
        body_str = try util.valueToStr(vm, args[2], &bbuf);
    }

    var client = std.http.Client{ .allocator = vm.allocator };
    defer client.deinit();

    var out: std.io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();

    var fetch_opts: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .method = method,
        .response_writer = &out.writer,
    };
    if (body_str) |b| fetch_opts.payload = b;

    const fetch_res = client.fetch(fetch_opts) catch |err| {
        return try util.makeErrorWithPayload(vm, "HttpError", try util.writeSlice(vm, @errorName(err)));
    };

    // Response-shaped module: .status / .body (matches std/http Response fields).
    const mod = try vm.allocModule("Response");
    const status_key = try vm.allocator.dupe(u8, "status");
    const body_key = try vm.allocator.dupe(u8, "body");
    try mod.props.put(status_key, .{ .int = @intCast(@intFromEnum(fetch_res.status)) });
    try mod.props.put(body_key, try util.writeSlice(vm, out.written()));
    return .{ .module = mod };
}

pub fn register(vm: *VMState) !void {
    fetch_n = .{ .name = "__fetch", .func = fetchFn, .arity = -1 }; // -1 for variadic
    try vm.defineGlobal("__fetch", .{ .native = &fetch_n });
}
