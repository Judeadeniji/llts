const std = @import("std");
const chunk_mod = @import("chunk.zig");
const opcode_mod = @import("opcode.zig");
const value_mod = @import("value.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = opcode_mod.OpCode;
const Value = value_mod.Value;

/// Operand bytes following the opcode (excluding the opcode byte itself).
fn operandBytes(op: OpCode) usize {
    return switch (op) {
        .OP_CONSTANT,
        .OP_GET_GLOBAL,
        .OP_SET_GLOBAL,
        .OP_GET_FUNCTION,
        .OP_GET_PROPERTY,
        .OP_SET_PROPERTY,
        .OP_GET_MODULE,
        .OP_IMPORT,
        .OP_SOURCE,
        .OP_JUMP,
        .OP_JUMP_IF_FALSE,
        .OP_LOOP,
        => 2,
        .OP_LINE => 4,
        .OP_CALL_STATIC => 3,
        .OP_GET_LOCAL,
        .OP_SET_LOCAL,
        .OP_PRINT,
        .OP_CALL,
        .OP_PACK_REST,
        .OP_MARK_CONST,
        .OP_ASSERT_TYPE,
        => 1,
        else => 0,
    };
}

fn readByte(code: []const u8, ip: *usize) ?u8 {
    if (ip.* >= code.len) return null;
    const b = code[ip.*];
    ip.* += 1;
    return b;
}

fn readShort(code: []const u8, ip: *usize) ?u16 {
    const hi: u16 = readByte(code, ip) orelse return null;
    const lo: u16 = readByte(code, ip) orelse return null;
    return (hi << 8) | lo;
}

fn formatValue(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    v: Value,
    buf: *std.ArrayList(u8),
) !void {
    const w = buf.writer(allocator);
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try w.print("{}", .{b}),
        .int => |n| try w.print("{}", .{n}),
        .float => |n| try w.print("{}", .{n}),
        .name => |i| {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, chunk.stringAt(i));
            try buf.append(allocator, '"');
        },
        .function => |f| try w.print("function {s}@{d}", .{ f.name, f.address }),
        .native => |n| try w.print("native {s}", .{n.name}),
        .ptr => |p| try w.print("ptr {d}", .{p}),
        .slice => |s| try w.print("slice offset={d} len={d}", .{ s.offset, s.len }),
        .bytes => |b| try w.print("bytes offset={d} len={d}", .{ b.offset, b.len }),
        .module => |m| try w.print("module {s}", .{m.name}),
        .list => try buf.appendSlice(allocator, "list"),
        .map => try buf.appendSlice(allocator, "map"),
        .buffer => try buf.appendSlice(allocator, "buffer"),
    }
}

fn formatConstIndex(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    idx: u16,
    buf: *std.ArrayList(u8),
) !void {
    const w = buf.writer(allocator);
    if (idx >= chunk.constants.items.len) {
        try w.print("{d} (out of range)", .{idx});
        return;
    }
    try w.print("{d} (", .{idx});
    try formatValue(allocator, chunk, chunk.constants.items[idx], buf);
    try buf.append(allocator, ')');
}

fn formatNameConst(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    idx: u16,
    buf: *std.ArrayList(u8),
) !void {
    const w = buf.writer(allocator);
    if (idx >= chunk.constants.items.len) {
        try w.print("{d} (out of range)", .{idx});
        return;
    }
    const v = chunk.constants.items[idx];
    switch (v) {
        .name => |i| try w.print("{d} ({s})", .{ idx, chunk.stringAt(i) }),
        else => try formatConstIndex(allocator, chunk, idx, buf),
    }
}

fn formatOperands(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    op: OpCode,
    code: []const u8,
    ip: *usize,
    buf: *std.ArrayList(u8),
) !bool {
    const w = buf.writer(allocator);
    switch (op) {
        .OP_CONSTANT => {
            const idx = readShort(code, ip) orelse return false;
            try formatConstIndex(allocator, chunk, idx, buf);
        },
        .OP_GET_GLOBAL,
        .OP_SET_GLOBAL,
        .OP_GET_FUNCTION,
        .OP_GET_MODULE,
        .OP_IMPORT,
        => {
            const idx = readShort(code, ip) orelse return false;
            try formatNameConst(allocator, chunk, idx, buf);
        },
        .OP_GET_PROPERTY,
        .OP_SET_PROPERTY,
        => {
            const idx = readShort(code, ip) orelse return false;
            try formatNameConst(allocator, chunk, idx, buf);
        },
        .OP_SOURCE => {
            const idx = readShort(code, ip) orelse return false;
            const src = chunk.sourceAt(idx);
            try w.print("{d} ({s})", .{ idx, src.path });
        },
        .OP_JUMP,
        .OP_JUMP_IF_FALSE,
        => {
            const offset = readShort(code, ip) orelse return false;
            const target = ip.* + offset;
            try w.print("{d} -> {d:0>4}", .{ offset, target });
        },
        .OP_LOOP => {
            const offset = readShort(code, ip) orelse return false;
            const target = ip.* - offset;
            try w.print("{d} -> {d:0>4}", .{ offset, target });
        },
        .OP_LINE => {
            const line = readShort(code, ip) orelse return false;
            const col = readShort(code, ip) orelse return false;
            try w.print("line={d} col={d}", .{ line, col });
        },
        .OP_CALL_STATIC => {
            const addr = readShort(code, ip) orelse return false;
            const argc = readByte(code, ip) orelse return false;
            try w.print("addr={d:0>4} argc={d}", .{ addr, argc });
        },
        .OP_GET_LOCAL,
        .OP_SET_LOCAL,
        .OP_PRINT,
        .OP_CALL,
        .OP_PACK_REST,
        .OP_MARK_CONST,
        .OP_ASSERT_TYPE,
        => {
            const b = readByte(code, ip) orelse return false;
            try w.print("{d}", .{b});
        },
        else => {},
    }
    return true;
}

pub fn dump(chunk: *const Chunk, writer: anytype) !void {
    const allocator = chunk.allocator;

    try writer.print("=== bytecode dump ===\n", .{});
    try writer.print("file: {s}\n", .{chunk.file});
    try writer.print("code: {d} bytes\n", .{chunk.code.items.len});
    try writer.print("constants: {d}\n", .{chunk.constants.items.len});
    try writer.print("strings: {d}\n", .{chunk.strings.items.len});
    try writer.print("functions: {d}\n", .{chunk.functions.count()});
    try writer.print("sources: {d}\n", .{chunk.sources.items.len});
    try writer.print("\n", .{});

    try writer.print("--- functions ---\n", .{});
    var fn_it = chunk.functions.iterator();
    while (fn_it.next()) |entry| {
        const f = entry.value_ptr.*;
        try writer.print(
            "{s}: addr={d:0>4} arity={d} variadic={} source_index={d}\n",
            .{ entry.key_ptr.*, f.address, f.arity, f.is_variadic, f.source_index },
        );
    }
    try writer.print("\n", .{});

    try writer.print("--- constants ---\n", .{});
    for (chunk.constants.items, 0..) |c, i| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try formatValue(allocator, chunk, c, &buf);
        try writer.print("{d:0>4}: {s}\n", .{ i, buf.items });
    }
    try writer.print("\n", .{});

    try writer.print("--- code ---\n", .{});
    const code = chunk.code.items;
    var ip: usize = 0;
    while (ip < code.len) {
        const ip_start = ip;
        const op_byte = readByte(code, &ip);
        if (op_byte == null) {
            try writer.print("{d:0>4}: <truncated>\n", .{ip_start});
            break;
        }

        const op: OpCode = @enumFromInt(op_byte.?);
        const op_name = @tagName(op);

        var operand_buf: std.ArrayList(u8) = .empty;
        defer operand_buf.deinit(allocator);

        const ok = try formatOperands(allocator, chunk, op, code, &ip, &operand_buf);
        if (!ok) {
            try writer.print("{d:0>4}: {s} <truncated operands>\n", .{ ip_start, op_name });
            break;
        }

        if (operand_buf.items.len > 0) {
            try writer.print("{d:0>4}: {s} {s}\n", .{ ip_start, op_name, operand_buf.items });
        } else {
            try writer.print("{d:0>4}: {s}\n", .{ ip_start, op_name });
        }

        const expected_end = ip_start + 1 + operandBytes(op);
        if (ip != expected_end) {
            try writer.print(
                "{d:0>4}: <warning: operand size mismatch, expected end {d:0>4}>\n",
                .{ ip_start, expected_end },
            );
            ip = expected_end;
        }
    }
}

test "disasm smoke chunk" {
    const allocator = std.testing.allocator;

    var c = Chunk.init(allocator);
    defer c.deinit();

    const idx = try c.addConstant(.{ .int = 42 });
    try c.writeOp(.OP_CONSTANT);
    try c.write(@intCast((idx >> 8) & 0xff));
    try c.write(@intCast(idx & 0xff));
    try c.writeOp(.OP_PRINT);
    try c.write(1);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try dump(&c, out.writer(allocator));

    const text = out.items;
    try std.testing.expect(std.mem.indexOf(u8, text, "OP_CONSTANT") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OP_PRINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "42") != null);
}
