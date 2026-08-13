const std = @import("std");
const chunk_mod = @import("chunk.zig");
const value_mod = @import("value.zig");

const Chunk = chunk_mod.Chunk;
const Value = value_mod.Value;

pub const magic: [4]u8 = .{ 'L', 'L', 'T', 'S' };
pub const version: u16 = 2;

pub const FormatError = error{
    InvalidMagic,
    UnsupportedVersion,
    TruncatedInput,
    InvalidConstantTag,
    InvalidStringIndex,
    OutOfMemory,
};

const ConstTag = enum(u8) {
    null_val = 0,
    bool_val = 1,
    int_val = 2,
    float_val = 3,
    name_val = 4,
};

const UsedStrings = struct {
    /// Old string-table indices in ascending order.
    indices: []u32,
    /// old_index -> new_index (u32 max = no mapping).
    remap: []u32,
};

fn writeU16(w: anytype, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try w.writeAll(&buf);
}

fn writeU32(w: anytype, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try w.writeAll(&buf);
}

fn writeI64(w: anytype, v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, v, .little);
    try w.writeAll(&buf);
}

fn writeF64(w: anytype, v: f64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(v), .little);
    try w.writeAll(&buf);
}

fn readU16(r: anytype) FormatError!u16 {
    var buf: [2]u8 = undefined;
    const n = r.read(&buf) catch return error.TruncatedInput;
    if (n != 2) return error.TruncatedInput;
    return std.mem.readInt(u16, &buf, .little);
}

fn readU32(r: anytype) FormatError!u32 {
    var buf: [4]u8 = undefined;
    const n = r.read(&buf) catch return error.TruncatedInput;
    if (n != 4) return error.TruncatedInput;
    return std.mem.readInt(u32, &buf, .little);
}

fn readI64(r: anytype) FormatError!i64 {
    var buf: [8]u8 = undefined;
    const n = r.read(&buf) catch return error.TruncatedInput;
    if (n != 8) return error.TruncatedInput;
    return std.mem.readInt(i64, &buf, .little);
}

fn readF64(r: anytype) FormatError!f64 {
    var buf: [8]u8 = undefined;
    const n = r.read(&buf) catch return error.TruncatedInput;
    if (n != 8) return error.TruncatedInput;
    return @bitCast(std.mem.readInt(u64, &buf, .little));
}

fn readExact(r: anytype, buf: []u8) FormatError!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = r.read(buf[off..]) catch return error.TruncatedInput;
        if (n == 0) return error.TruncatedInput;
        off += n;
    }
}

fn readString(r: anytype, allocator: std.mem.Allocator) FormatError![]u8 {
    const len = readU32(r) catch return error.TruncatedInput;
    const owned = allocator.alloc(u8, len) catch return error.OutOfMemory;
    errdefer allocator.free(owned);
    readExact(r, owned) catch return error.TruncatedInput;
    return owned;
}

fn writeString(w: anytype, s: []const u8) !void {
    try writeU32(w, @intCast(s.len));
    try w.writeAll(s);
}

fn stringIndex(chunk: *const Chunk, s: []const u8) ?u32 {
    for (chunk.strings.items, 0..) |str, i| {
        if (str.ptr == s.ptr or std.mem.eql(u8, str, s)) return @intCast(i);
    }
    return null;
}

fn collectUsedStrings(allocator: std.mem.Allocator, chunk: *const Chunk) !UsedStrings {
    var used = std.AutoHashMap(u32, void).init(allocator);
    defer used.deinit();

    for (chunk.constants.items) |c| {
        if (c == .name) try used.put(c.name, {});
    }

    var fit = chunk.functions.iterator();
    while (fit.next()) |entry| {
        if (stringIndex(chunk, entry.key_ptr.*)) |idx| try used.put(idx, {});
    }

    const indices = try allocator.alloc(u32, used.count());
    errdefer allocator.free(indices);
    var remap = try allocator.alloc(u32, chunk.strings.items.len);
    errdefer allocator.free(remap);
    @memset(remap, std.math.maxInt(u32));

    var i: usize = 0;
    var it = used.keyIterator();
    while (it.next()) |idx| {
        indices[i] = idx.*;
        i += 1;
    }
    std.mem.sort(u32, indices, {}, std.sort.asc(u32));

    for (indices, 0..) |old, new| remap[old] = @intCast(new);

    return .{ .indices = indices, .remap = remap };
}

fn writeConstant(w: anytype, v: Value, remap: []const u32) !void {
    switch (v) {
        .null => try w.writeAll(&.{@intFromEnum(ConstTag.null_val)}),
        .bool => |b| {
            try w.writeAll(&.{@intFromEnum(ConstTag.bool_val)});
            try w.writeAll(&.{@intFromBool(b)});
        },
        .int => |n| {
            try w.writeAll(&.{@intFromEnum(ConstTag.int_val)});
            try writeI64(w, n);
        },
        .float => |n| {
            try w.writeAll(&.{@intFromEnum(ConstTag.float_val)});
            try writeF64(w, n);
        },
        .name => |idx| {
            const new_idx = remap[idx];
            try w.writeAll(&.{@intFromEnum(ConstTag.name_val)});
            try writeU32(w, new_idx);
        },
        else => unreachable,
    }
}

fn readConstant(r: anytype, string_count: u32) FormatError!Value {
    var tag_buf: [1]u8 = undefined;
    readExact(r, &tag_buf) catch return error.TruncatedInput;
    if (tag_buf[0] > @intFromEnum(ConstTag.name_val)) return error.InvalidConstantTag;
    const tag: ConstTag = @enumFromInt(tag_buf[0]);
    return switch (tag) {
        .null_val => .null,
        .bool_val => blk: {
            var b_buf: [1]u8 = undefined;
            readExact(r, &b_buf) catch return error.TruncatedInput;
            break :blk Value{ .bool = b_buf[0] != 0 };
        },
        .int_val => .{ .int = try readI64(r) },
        .float_val => .{ .float = try readF64(r) },
        .name_val => blk: {
            const idx = try readU32(r);
            if (idx >= string_count) return error.InvalidStringIndex;
            break :blk Value{ .name = idx };
        },
    };
}

/// Write execution bytecode only: code, referenced strings/constants, functions, entry path.
pub fn write(chunk: *const Chunk, writer: anytype) !void {
    const allocator = chunk.allocator;
    const used = try collectUsedStrings(allocator, chunk);
    defer allocator.free(used.indices);
    defer allocator.free(used.remap);

    try writer.writeAll(&magic);
    try writeU16(writer, version);
    try writeU16(writer, 0); // flags (reserved)

    try writeU32(writer, @intCast(chunk.code.items.len));
    try writer.writeAll(chunk.code.items);

    try writeU32(writer, @intCast(used.indices.len));
    for (used.indices) |idx| try writeString(writer, chunk.strings.items[idx]);

    try writeU32(writer, @intCast(chunk.constants.items.len));
    for (chunk.constants.items) |c| try writeConstant(writer, c, used.remap);

    try writeU32(writer, @intCast(chunk.functions.count()));
    var func_it = chunk.functions.iterator();
    while (func_it.next()) |entry| {
        const name_idx = stringIndex(chunk, entry.key_ptr.*) orelse return error.InvalidStringIndex;
        const new_idx = used.remap[name_idx];
        try writeU32(writer, new_idx);
        try writeU32(writer, entry.value_ptr.address);
        try writer.writeAll(&.{entry.value_ptr.arity});
        try writer.writeAll(&.{@intFromBool(entry.value_ptr.is_variadic)});
    }

    try writeString(writer, chunk.file);
}

fn readV2(allocator: std.mem.Allocator, reader: anytype) FormatError!Chunk {
    var chunk = Chunk.init(allocator);
    errdefer chunk.deinit();

    const code_len = try readU32(reader);
    try chunk.code.ensureTotalCapacityPrecise(allocator, code_len);
    chunk.code.items.len = code_len;
    readExact(reader, chunk.code.items) catch return error.TruncatedInput;

    const string_count = try readU32(reader);
    try chunk.strings.ensureTotalCapacityPrecise(allocator, string_count);
    var s: u32 = 0;
    while (s < string_count) : (s += 1) {
        const owned = try readString(reader, allocator);
        try chunk.strings.append(allocator, owned);
    }

    const const_count = try readU32(reader);
    try chunk.constants.ensureTotalCapacityPrecise(allocator, const_count);
    var c: u32 = 0;
    while (c < const_count) : (c += 1) {
        try chunk.constants.append(allocator, try readConstant(reader, string_count));
    }

    const func_count = try readU32(reader);
    var f: u32 = 0;
    while (f < func_count) : (f += 1) {
        const name_idx = try readU32(reader);
        if (name_idx >= string_count) return error.InvalidStringIndex;
        const name = chunk.strings.items[name_idx];
        const address = try readU32(reader);
        var arity_buf: [1]u8 = undefined;
        readExact(reader, &arity_buf) catch return error.TruncatedInput;
        var variadic_buf: [1]u8 = undefined;
        readExact(reader, &variadic_buf) catch return error.TruncatedInput;
        try chunk.functions.put(name, .{
            .name = name,
            .address = address,
            .arity = arity_buf[0],
            .is_variadic = variadic_buf[0] != 0,
            .source_index = 0,
        });
    }

    const file_path = try readString(reader, allocator);
    errdefer allocator.free(file_path);
    if (file_path.len > 0) {
        const empty = try allocator.dupe(u8, "");
        errdefer allocator.free(empty);
        try chunk.sources.append(allocator, .{ .path = file_path, .text = empty });
        chunk.file = chunk.sources.items[0].path;
        chunk.source = chunk.sources.items[0].text;
    } else {
        allocator.free(file_path);
        chunk.file = "<anonymous>";
        chunk.source = "";
    }

    return chunk;
}

/// Read v1 artifacts (included full sources/exports — deprecated).
fn readV1(allocator: std.mem.Allocator, reader: anytype) FormatError!Chunk {
    var chunk = Chunk.init(allocator);
    errdefer chunk.deinit();

    const code_len = try readU32(reader);
    try chunk.code.ensureTotalCapacityPrecise(allocator, code_len);
    chunk.code.items.len = code_len;
    readExact(reader, chunk.code.items) catch return error.TruncatedInput;

    const string_count = try readU32(reader);
    try chunk.strings.ensureTotalCapacityPrecise(allocator, string_count);
    var s: u32 = 0;
    while (s < string_count) : (s += 1) {
        const owned = try readString(reader, allocator);
        try chunk.strings.append(allocator, owned);
    }

    const const_count = try readU32(reader);
    try chunk.constants.ensureTotalCapacityPrecise(allocator, const_count);
    var c: u32 = 0;
    while (c < const_count) : (c += 1) {
        try chunk.constants.append(allocator, try readConstant(reader, string_count));
    }

    const func_count = try readU32(reader);
    var f: u32 = 0;
    while (f < func_count) : (f += 1) {
        const name = try readString(reader, allocator);
        try chunk.strings.append(allocator, name);
        const address = try readU32(reader);
        var arity_buf: [1]u8 = undefined;
        readExact(reader, &arity_buf) catch return error.TruncatedInput;
        var variadic_buf: [1]u8 = undefined;
        readExact(reader, &variadic_buf) catch return error.TruncatedInput;
        const source_index = try readU16(reader);
        try chunk.functions.put(name, .{
            .name = name,
            .address = address,
            .arity = arity_buf[0],
            .is_variadic = variadic_buf[0] != 0,
            .source_index = source_index,
        });
    }

    const export_count = try readU32(reader);
    var e: u32 = 0;
    while (e < export_count) : (e += 1) {
        const name = try readString(reader, allocator);
        try chunk.strings.append(allocator, name);
        try chunk.exports.put(name, {});
    }

    const file_path = try readString(reader, allocator);
    errdefer allocator.free(file_path);

    const source_count = try readU32(reader);
    try chunk.sources.ensureTotalCapacityPrecise(allocator, source_count);
    var i: u32 = 0;
    while (i < source_count) : (i += 1) {
        const path = try readString(reader, allocator);
        errdefer allocator.free(path);
        const text = try readString(reader, allocator);
        try chunk.sources.append(allocator, .{ .path = path, .text = text });
    }

    if (chunk.sources.items.len > 0) {
        allocator.free(file_path);
        chunk.file = chunk.sources.items[0].path;
        chunk.source = chunk.sources.items[0].text;
    } else if (file_path.len > 0) {
        const empty = try allocator.dupe(u8, "");
        errdefer allocator.free(empty);
        try chunk.sources.append(allocator, .{ .path = file_path, .text = empty });
        chunk.file = chunk.sources.items[0].path;
        chunk.source = chunk.sources.items[0].text;
    } else {
        allocator.free(file_path);
        chunk.file = "<anonymous>";
        chunk.source = "";
    }

    return chunk;
}

/// Read binary bytecode written by `write` into a fresh chunk.
pub fn read(allocator: std.mem.Allocator, reader: anytype) FormatError!Chunk {
    var header: [4]u8 = undefined;
    readExact(reader, &header) catch return error.TruncatedInput;
    if (!std.mem.eql(u8, &header, &magic)) return error.InvalidMagic;

    const file_version = try readU16(reader);
    _ = try readU16(reader); // flags

    return switch (file_version) {
        1 => readV1(allocator, reader),
        2 => readV2(allocator, reader),
        else => error.UnsupportedVersion,
    };
}

pub fn writeFile(allocator: std.mem.Allocator, chunk: *const Chunk, path: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try write(chunk, buf.writer(allocator));
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) FormatError!Chunk {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch return error.TruncatedInput;
    defer allocator.free(data);
    var stream = std.io.fixedBufferStream(data);
    return read(allocator, stream.reader());
}

pub fn isBytecodePath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".llb");
}

test "round-trip lean chunk" {
    const allocator = std.testing.allocator;

    var c = Chunk.init(allocator);
    defer c.deinit();

    _ = try c.addSource("test.lls", "print(1);");
    c.file = c.sources.items[0].path;
    c.source = c.sources.items[0].text;

    const name_idx = try c.addStringConstant("print");
    const int_idx = try c.addConstant(.{ .int = 42 });
    try c.writeOp(.OP_CONSTANT);
    try c.write(@intCast((int_idx >> 8) & 0xff));
    try c.write(@intCast(int_idx & 0xff));
    try c.writeOp(.OP_GET_GLOBAL);
    try c.write(@intCast((name_idx >> 8) & 0xff));
    try c.write(@intCast(name_idx & 0xff));
    try c.writeOp(.OP_CALL);
    try c.write(1);
    try c.writeOp(.OP_NULL);
    try c.writeOp(.OP_RETURN);

    // Noise that must not appear in the artifact.
    _ = try c.internString("unused_global_from_stdlib");

    const fn_name = try c.internString("main");
    try c.functions.put(fn_name, .{
        .name = fn_name,
        .address = 0,
        .arity = 0,
        .source_index = 0,
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try write(&c, buf.writer(allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    var loaded = try read(allocator, stream.reader());
    defer loaded.deinit();

    try std.testing.expectEqualSlices(u8, c.code.items, loaded.code.items);
    try std.testing.expectEqual(@as(usize, 2), loaded.strings.items.len); // print + main
    try std.testing.expectEqual(@as(usize, 1), loaded.functions.count());
    try std.testing.expectEqual(@as(usize, 0), loaded.exports.count());
    try std.testing.expectEqual(@as(usize, 1), loaded.sources.items.len);
    try std.testing.expectEqualStrings("", loaded.sources.items[0].text);
}
