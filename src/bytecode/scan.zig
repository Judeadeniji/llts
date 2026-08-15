const std = @import("std");
const chunk_mod = @import("chunk.zig");
const opcode_mod = @import("opcode.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = opcode_mod.OpCode;

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
        .OP_FOR_PREP, .OP_FOR_LOOP => 4,
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

fn readShort(code: []const u8, ip: *usize) ?u16 {
    if (ip.* + 1 >= code.len) return null;
    const hi: u16 = code[ip.*];
    ip.* += 1;
    const lo: u16 = code[ip.*];
    ip.* += 1;
    return (hi << 8) | lo;
}

/// Collect global names referenced by `OP_GET_GLOBAL` / `OP_SET_GLOBAL` in `chunk.code`.
pub fn referencedGlobalNames(allocator: std.mem.Allocator, chunk: *const Chunk) !std.StringHashMap(void) {
    var names = std.StringHashMap(void).init(allocator);
    errdefer names.deinit();

    const code = chunk.code.items;
    var ip: usize = 0;
    while (ip < code.len) {
        const ip_start = ip;
        const op: OpCode = @enumFromInt(code[ip]);
        ip += 1;

        switch (op) {
            .OP_GET_GLOBAL, .OP_SET_GLOBAL => {
                const slot = readShort(code, &ip) orelse break;
                if (slot < chunk.global_names.items.len) {
                    try names.put(chunk.global_names.items[slot], {});
                }
            },
            else => {},
        }

        const expected = ip_start + 1 + operandBytes(op);
        if (ip < expected) ip = expected;
    }

    return names;
}

test "scan finds globals in chunk" {
    const allocator = std.testing.allocator;

    var c = Chunk.init(allocator);
    defer c.deinit();

    const print_slot = try c.internGlobalName("print");
    const host_slot = try c.internGlobalName("__hostLog");
    try c.writeOp(.OP_GET_GLOBAL);
    try c.write(@intCast((host_slot >> 8) & 0xff));
    try c.write(@intCast(host_slot & 0xff));
    try c.writeOp(.OP_GET_GLOBAL);
    try c.write(@intCast((print_slot >> 8) & 0xff));
    try c.write(@intCast(print_slot & 0xff));

    var names = try referencedGlobalNames(allocator, &c);
    defer names.deinit();

    try std.testing.expect(names.contains("__hostLog"));
    try std.testing.expect(names.contains("print"));
}
