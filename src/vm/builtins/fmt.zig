const std = @import("std");
const state_mod = @import("../state.zig");
const value = @import("../../bytecode/value.zig");
const widths = @import("../../compiler/widths.zig");
const out_mod = @import("../../io/out.zig");
const util = @import("util.zig");

const VMState = state_mod.VMState;
const Value = value.Value;
const NativeFunction = value.NativeFunction;
const ERROR_TAG = state_mod.ERROR_TAG;

const ldigits = "0123456789abcdefx";
const udigits = "0123456789ABCDEFX";

pub const FmtFlags = struct {
    wid_present: bool = false,
    prec_present: bool = false,
    minus: bool = false,
    plus: bool = false,
    sharp: bool = false,
    space: bool = false,
    zero: bool = false,
    plus_v: bool = false,
    sharp_v: bool = false,
    wid: i32 = 0,
    prec: i32 = 0,

    pub fn clear(self: *FmtFlags) void {
        self.* = .{};
    }
};

pub const Formatter = struct {
    vm: *VMState,
    out: *std.ArrayList(u8),
    flags: FmtFlags = .{},

    pub fn init(vm: *VMState, out: *std.ArrayList(u8)) Formatter {
        return .{
            .vm = vm,
            .out = out,
        };
    }

    pub fn writePadding(self: *Formatter, n: i32, pad_byte: u8) !void {
        if (n <= 0) return;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            try self.out.append(self.vm.allocator, pad_byte);
        }
    }

    pub fn padBytes(self: *Formatter, b: []const u8) !void {
        if (!self.flags.wid_present or self.flags.wid <= @as(i32, @intCast(b.len))) {
            try self.out.appendSlice(self.vm.allocator, b);
            return;
        }
        const pad_len = self.flags.wid - @as(i32, @intCast(b.len));
        if (self.flags.minus) {
            try self.out.appendSlice(self.vm.allocator, b);
            try self.writePadding(pad_len, ' ');
        } else {
            const pad_char: u8 = if (self.flags.zero) '0' else ' ';
            try self.writePadding(pad_len, pad_char);
            try self.out.appendSlice(self.vm.allocator, b);
        }
    }

    pub fn padPrefixAndBytes(self: *Formatter, prefix: []const u8, digits: []const u8) !void {
        const total_len: i32 = @intCast(prefix.len + digits.len);
        if (!self.flags.wid_present or self.flags.wid <= total_len) {
            try self.out.appendSlice(self.vm.allocator, prefix);
            try self.out.appendSlice(self.vm.allocator, digits);
            return;
        }
        const pad_len = self.flags.wid - total_len;
        if (self.flags.minus) {
            try self.out.appendSlice(self.vm.allocator, prefix);
            try self.out.appendSlice(self.vm.allocator, digits);
            try self.writePadding(pad_len, ' ');
        } else if (self.flags.zero) {
            try self.out.appendSlice(self.vm.allocator, prefix);
            try self.writePadding(pad_len, '0');
            try self.out.appendSlice(self.vm.allocator, digits);
        } else {
            try self.writePadding(pad_len, ' ');
            try self.out.appendSlice(self.vm.allocator, prefix);
            try self.out.appendSlice(self.vm.allocator, digits);
        }
    }

    pub fn formatBool(self: *Formatter, b: bool) !void {
        const s = if (b) "true" else "false";
        try self.padBytes(s);
    }

    pub fn formatInteger(self: *Formatter, raw_u64: u64, is_signed: bool, base: u8, uppercase: bool, verb: u8) !void {
        var negative = false;
        var u = raw_u64;
        if (is_signed) {
            const i_val: i64 = @bitCast(raw_u64);
            if (i_val < 0) {
                negative = true;
                u = @as(u64, 0) -% raw_u64;
            }
        }

        var prefix_buf: [4]u8 = undefined;
        var prefix_len: usize = 0;
        if (negative) {
            prefix_buf[prefix_len] = '-';
            prefix_len += 1;
        } else if (self.flags.plus) {
            prefix_buf[prefix_len] = '+';
            prefix_len += 1;
        } else if (self.flags.space) {
            prefix_buf[prefix_len] = ' ';
            prefix_len += 1;
        }

        const digits_table = if (uppercase) udigits else ldigits;

        if (self.flags.sharp) {
            switch (base) {
                2 => {
                    prefix_buf[prefix_len] = '0';
                    prefix_buf[prefix_len + 1] = 'b';
                    prefix_len += 2;
                },
                8 => {
                    prefix_buf[prefix_len] = '0';
                    prefix_len += 1;
                },
                16 => {
                    prefix_buf[prefix_len] = '0';
                    prefix_buf[prefix_len + 1] = if (uppercase) 'X' else 'x';
                    prefix_len += 2;
                },
                else => {},
            }
        } else if (verb == 'O') {
            prefix_buf[prefix_len] = '0';
            prefix_buf[prefix_len + 1] = 'o';
            prefix_len += 2;
        }

        var num_buf: [70]u8 = undefined;
        var num_idx: usize = num_buf.len;

        if (self.flags.prec_present and self.flags.prec == 0 and u == 0) {
            // Precision of 0 and value 0 yields no digits
        } else if (u == 0) {
            num_idx -= 1;
            num_buf[num_idx] = '0';
        } else {
            const b_u64: u64 = base;
            while (u > 0) {
                num_idx -= 1;
                const rem: usize = @intCast(u % b_u64);
                num_buf[num_idx] = digits_table[rem];
                u /= b_u64;
            }
        }

        // Apply precision padding (leading zeros on digits)
        const digits_len: i32 = @intCast(num_buf.len - num_idx);
        var prec_zeros: i32 = 0;
        if (self.flags.prec_present and self.flags.prec > digits_len) {
            prec_zeros = self.flags.prec - digits_len;
        }

        var full_digits: std.ArrayList(u8) = .empty;
        defer full_digits.deinit(self.vm.allocator);
        var pz: i32 = 0;
        while (pz < prec_zeros) : (pz += 1) {
            try full_digits.append(self.vm.allocator, '0');
        }
        try full_digits.appendSlice(self.vm.allocator, num_buf[num_idx..]);

        try self.padPrefixAndBytes(prefix_buf[0..prefix_len], full_digits.items);
    }

    pub fn formatRune(self: *Formatter, code: u32) !void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(code), &buf) catch blk: {
            buf[0] = '?';
            break :blk 1;
        };
        try self.padBytes(buf[0..len]);
    }

    pub fn formatQuotedRune(self: *Formatter, code: u32) !void {
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        buf[len] = '\'';
        len += 1;
        switch (code) {
            '\'' => {
                buf[len] = '\\';
                buf[len + 1] = '\'';
                len += 2;
            },
            '\\' => {
                buf[len] = '\\';
                buf[len + 1] = '\\';
                len += 2;
            },
            '\n' => {
                buf[len] = '\\';
                buf[len + 1] = 'n';
                len += 2;
            },
            '\r' => {
                buf[len] = '\\';
                buf[len + 1] = 'r';
                len += 2;
            },
            '\t' => {
                buf[len] = '\\';
                buf[len + 1] = 't';
                len += 2;
            },
            else => {
                if (code >= 32 and code < 127) {
                    buf[len] = @intCast(code);
                    len += 1;
                } else {
                    const encoded = std.fmt.bufPrint(buf[len..], "\\u{x:0>4}", .{code}) catch "\\u????";
                    len += encoded.len;
                }
            },
        }
        buf[len] = '\'';
        len += 1;
        try self.padBytes(buf[0..len]);
    }

    pub fn formatUnicode(self: *Formatter, code: u64) !void {
        var buf: [64]u8 = undefined;
        const formatted = if (self.flags.sharp and code <= 0x10FFFF and code >= 32 and code != 127)
            try std.fmt.bufPrint(&buf, "U+{X:0>4} '{u}'", .{ code, @as(u21, @intCast(code)) })
        else
            try std.fmt.bufPrint(&buf, "U+{X:0>4}", .{code});
        try self.padBytes(formatted);
    }

    pub fn formatFloat(self: *Formatter, f: f64, verb: u8) !void {
        if (std.math.isNan(f)) {
            try self.padBytes("NaN");
            return;
        }
        if (std.math.isInf(f)) {
            if (f < 0) {
                try self.padBytes("-Inf");
            } else if (self.flags.plus) {
                try self.padBytes("+Inf");
            } else {
                try self.padBytes("Inf");
            }
            return;
        }

        var prefix_buf: [2]u8 = undefined;
        var prefix_len: usize = 0;
        var abs_f = f;
        if (std.math.signbit(f)) {
            prefix_buf[prefix_len] = '-';
            prefix_len += 1;
            abs_f = -f;
        } else if (self.flags.plus) {
            prefix_buf[prefix_len] = '+';
            prefix_len += 1;
        } else if (self.flags.space) {
            prefix_buf[prefix_len] = ' ';
            prefix_len += 1;
        }

        const prec: usize = if (self.flags.prec_present) @intCast(@max(0, self.flags.prec)) else 6;

        var buf: [128]u8 = undefined;
        var formatted: []const u8 = "";

        switch (verb) {
            'e' => {
                formatted = try std.fmt.bufPrint(&buf, "{e}", .{abs_f});
            },
            'E' => {
                var tmp: [128]u8 = undefined;
                const lower_str = try std.fmt.bufPrint(&tmp, "{e}", .{abs_f});
                var idx: usize = 0;
                for (lower_str) |c| {
                    buf[idx] = std.ascii.toUpper(c);
                    idx += 1;
                }
                formatted = buf[0..idx];
            },
            'g', 'G', 'v' => {
                if (abs_f == @floor(abs_f) and abs_f < 1e12 and !self.flags.prec_present) {
                    formatted = try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(abs_f))});
                } else if (self.flags.prec_present) {
                    formatted = try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs_f, prec });
                } else {
                    formatted = try std.fmt.bufPrint(&buf, "{d}", .{abs_f});
                }
            },
            else => { // 'f', 'F'
                formatted = try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs_f, prec });
            },
        }

        try self.padPrefixAndBytes(prefix_buf[0..prefix_len], formatted);
    }

    pub fn formatString(self: *Formatter, s: []const u8, verb: u8) !void {
        var str = s;
        if (self.flags.prec_present and self.flags.prec >= 0 and @as(usize, @intCast(self.flags.prec)) < str.len) {
            str = str[0..@intCast(self.flags.prec)];
        }

        switch (verb) {
            'q' => {
                if (self.flags.sharp and std.mem.indexOfScalar(u8, str, '`') == null) {
                    var qbuf: std.ArrayList(u8) = .empty;
                    defer qbuf.deinit(self.vm.allocator);
                    try qbuf.append(self.vm.allocator, '`');
                    try qbuf.appendSlice(self.vm.allocator, str);
                    try qbuf.append(self.vm.allocator, '`');
                    try self.padBytes(qbuf.items);
                } else {
                    var qbuf: std.ArrayList(u8) = .empty;
                    defer qbuf.deinit(self.vm.allocator);
                    try qbuf.append(self.vm.allocator, '"');
                    for (str) |c| {
                        switch (c) {
                            '"' => try qbuf.appendSlice(self.vm.allocator, "\\\""),
                            '\\' => try qbuf.appendSlice(self.vm.allocator, "\\\\"),
                            '\n' => try qbuf.appendSlice(self.vm.allocator, "\\n"),
                            '\r' => try qbuf.appendSlice(self.vm.allocator, "\\r"),
                            '\t' => try qbuf.appendSlice(self.vm.allocator, "\\t"),
                            else => {
                                if (c < 32 or (self.flags.plus and c >= 127)) {
                                    var esc: [8]u8 = undefined;
                                    const es = try std.fmt.bufPrint(&esc, "\\x{x:0>2}", .{c});
                                    try qbuf.appendSlice(self.vm.allocator, es);
                                } else {
                                    try qbuf.append(self.vm.allocator, c);
                                }
                            },
                        }
                    }
                    try qbuf.append(self.vm.allocator, '"');
                    try self.padBytes(qbuf.items);
                }
            },
            'x', 'X' => {
                var hbuf: std.ArrayList(u8) = .empty;
                defer hbuf.deinit(self.vm.allocator);
                const hex_digits = if (verb == 'X') udigits else ldigits;
                for (str, 0..) |c, idx| {
                    if (self.flags.space and idx > 0) try hbuf.append(self.vm.allocator, ' ');
                    try hbuf.append(self.vm.allocator, hex_digits[(c >> 4) & 0xF]);
                    try hbuf.append(self.vm.allocator, hex_digits[c & 0xF]);
                }
                try self.padBytes(hbuf.items);
            },
            else => {
                try self.padBytes(str);
            },
        }
    }

    pub fn formatTypeName(self: *Formatter, v: Value) !void {
        const name = switch (v) {
            .null => "nil",
            .u1 => "bool",
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "int",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .f32 => "float32",
            .f64 => "float64",
            .name, .slice => "string",
            .bytes => "[]byte",
            .array => "[]any",
            .ptr => |p| blk: {
                if (self.vm.isValidHeapPtr(p - 1) and self.vm.slot(p - 1).*.i64 == ERROR_TAG) {
                    break :blk "error";
                }
                break :blk "*any";
            },
            .function => "func",
            .native => "builtin",
            .module => "module",
            .list => "list",
            .map => "map",
            .buffer => "Buffer",
        };
        try self.padBytes(name);
    }

    pub fn formatPointer(self: *Formatter, p: i32) !void {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "0x{x}", .{p});
        try self.padBytes(s);
    }

    pub fn formatValue(self: *Formatter, v: Value, verb: u8, depth: usize) !void {
        switch (verb) {
            'T' => {
                try self.formatTypeName(v);
                return;
            },
            'p' => {
                switch (v) {
                    .ptr => |p| try self.formatPointer(p),
                    else => {
                        const n = widths.valueAsI64(v) orelse 0;
                        try self.formatPointer(@intCast(n));
                    },
                }
                return;
            },
            't' => {
                try self.formatBool(v.isTruthy());
                return;
            },
            'b' => {
                const n: u64 = @bitCast(widths.valueAsI64(v) orelse 0);
                try self.formatInteger(n, false, 2, false, 'b');
                return;
            },
            'o' => {
                const n: u64 = @bitCast(widths.valueAsI64(v) orelse 0);
                try self.formatInteger(n, false, 8, false, 'o');
                return;
            },
            'O' => {
                const n: u64 = @bitCast(widths.valueAsI64(v) orelse 0);
                try self.formatInteger(n, false, 8, false, 'O');
                return;
            },
            'd' => {
                const n: i64 = widths.valueAsI64(v) orelse 0;
                try self.formatInteger(@bitCast(n), true, 10, false, 'd');
                return;
            },
            'x', 'X' => {
                if (v == .name or v == .slice or v == .bytes) {
                    var sbuf: std.ArrayList(u8) = .empty;
                    defer sbuf.deinit(self.vm.allocator);
                    const s = try util.valueToStr(self.vm, v, &sbuf);
                    try self.formatString(s, verb);
                    return;
                }
                const n: u64 = @bitCast(widths.valueAsI64(v) orelse 0);
                try self.formatInteger(n, false, 16, verb == 'X', verb);
                return;
            },
            'c' => {
                const n = widths.valueAsI64(v) orelse 0;
                try self.formatRune(@intCast(n));
                return;
            },
            'q' => {
                if (v == .name or v == .slice or v == .bytes) {
                    var sbuf: std.ArrayList(u8) = .empty;
                    defer sbuf.deinit(self.vm.allocator);
                    const s = try util.valueToStr(self.vm, v, &sbuf);
                    try self.formatString(s, 'q');
                    return;
                }
                const n = widths.valueAsI64(v) orelse 0;
                try self.formatQuotedRune(@intCast(n));
                return;
            },
            'U' => {
                const n: u64 = @bitCast(widths.valueAsI64(v) orelse 0);
                try self.formatUnicode(n);
                return;
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                const flt: f64 = switch (v) {
                    .f32 => |f| @floatCast(f),
                    .f64 => |f| f,
                    else => if (widths.valueAsI64(v)) |n| @floatFromInt(n) else 0.0,
                };
                try self.formatFloat(flt, verb);
                return;
            },
            's' => {
                var sbuf: std.ArrayList(u8) = .empty;
                defer sbuf.deinit(self.vm.allocator);
                if (v == .name or v == .slice or v == .bytes) {
                    const s = try util.valueToStr(self.vm, v, &sbuf);
                    try self.formatString(s, 's');
                } else {
                    try self.formatValue(v, 'v', depth);
                }
                return;
            },
            'v' => {
                // Handled below
            },
            else => {
                try self.out.appendSlice(self.vm.allocator, "%!");
                try self.out.append(self.vm.allocator, verb);
                try self.out.append(self.vm.allocator, '(');
                try self.formatTypeName(v);
                try self.out.append(self.vm.allocator, '=');
                try self.formatValue(v, 'v', depth + 1);
                try self.out.append(self.vm.allocator, ')');
                return;
            },
        }

        switch (v) {
            .null => try self.padBytes(if (self.flags.sharp_v) "nil" else "null"),
            .u1 => |b| try self.formatBool(b != 0),
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => {
                const n = widths.valueAsI64(v) orelse 0;
                try self.formatInteger(@bitCast(n), true, 10, false, 'd');
            },
            .f32 => |f| try self.formatFloat(@floatCast(f), 'g'),
            .f64 => |f| try self.formatFloat(f, 'g'),
            .name, .slice => {
                var sbuf: std.ArrayList(u8) = .empty;
                defer sbuf.deinit(self.vm.allocator);
                const s = try util.valueToStr(self.vm, v, &sbuf);
                if (self.flags.sharp_v) {
                    try self.formatString(s, 'q');
                } else {
                    try self.formatString(s, 's');
                }
            },
            .bytes => |b| {
                const data = self.vm.bytes.items[b.offset..][0..b.len];
                if (self.flags.sharp_v) {
                    var sbuf: std.ArrayList(u8) = .empty;
                    defer sbuf.deinit(self.vm.allocator);
                    try sbuf.appendSlice(self.vm.allocator, "[]byte{");
                    for (data, 0..) |ch, i| {
                        if (i > 0) try sbuf.appendSlice(self.vm.allocator, ", ");
                        var num_str: [8]u8 = undefined;
                        const ns = try std.fmt.bufPrint(&num_str, "{d}", .{ch});
                        try sbuf.appendSlice(self.vm.allocator, ns);
                    }
                    try sbuf.append(self.vm.allocator, '}');
                    try self.padBytes(sbuf.items);
                } else {
                    var printable = true;
                    for (data) |ch| {
                        if ((ch < 32 or ch > 126) and ch != '\n' and ch != '\t') {
                            printable = false;
                            break;
                        }
                    }
                    if (printable) {
                        try self.padBytes(data);
                    } else {
                        var abuf: std.ArrayList(u8) = .empty;
                        defer abuf.deinit(self.vm.allocator);
                        try abuf.append(self.vm.allocator, '[');
                        for (data, 0..) |ch, i| {
                            if (i > 0) try abuf.append(self.vm.allocator, ' ');
                            var num_str: [8]u8 = undefined;
                            const ns = try std.fmt.bufPrint(&num_str, "{d}", .{ch});
                            try abuf.appendSlice(self.vm.allocator, ns);
                        }
                        try abuf.append(self.vm.allocator, ']');
                        try self.padBytes(abuf.items);
                    }
                }
            },
            .array => |a| {
                var abuf: std.ArrayList(u8) = .empty;
                defer abuf.deinit(self.vm.allocator);
                var sub_fmt = Formatter.init(self.vm, &abuf);
                sub_fmt.flags = self.flags;
                try abuf.append(self.vm.allocator, '[');
                var i: u32 = 0;
                while (i < a.count) : (i += 1) {
                    if (i > 0) try abuf.append(self.vm.allocator, ' ');
                    const elem = self.vm.arrayElemConst(a, i);
                    try sub_fmt.formatValue(elem, 'v', depth + 1);
                }
                try abuf.append(self.vm.allocator, ']');
                try self.padBytes(abuf.items);
            },
            .ptr => |p| {
                if (p < 1 or !self.vm.isValidHeapPtr(p - 1)) {
                    try self.formatPointer(p);
                    return;
                }
                const header_val = self.vm.slot(p - 1).*;
                if (header_val == .i64 and header_val.i64 == ERROR_TAG) {
                    var ebuf: std.ArrayList(u8) = .empty;
                    defer ebuf.deinit(self.vm.allocator);
                    var sub_fmt = Formatter.init(self.vm, &ebuf);
                    try sub_fmt.formatValue(self.vm.slot(p).*, 'v', depth + 1);
                    const payload = self.vm.slot(p + 1).*;
                    if (payload != .null) {
                        if (self.flags.plus_v) {
                            try ebuf.appendSlice(self.vm.allocator, " (payload: ");
                            try sub_fmt.formatValue(payload, 'v', depth + 1);
                            try ebuf.append(self.vm.allocator, ')');
                        } else {
                            try ebuf.appendSlice(self.vm.allocator, " — ");
                            try sub_fmt.formatValue(payload, 'v', depth + 1);
                        }
                    }
                    try self.padBytes(ebuf.items);
                    return;
                }
                if (header_val == .i64 and header_val.i64 >= 0 and header_val.i64 < 64 * 1024 * 1024) {
                    const len: usize = @intCast(header_val.i64);
                    var is_str = true;
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        const val = self.vm.slot(p + @as(i32, @intCast(i))).*;
                        if (val != .i64 or val.i64 < 32 or val.i64 > 126) {
                            if (val == .i64 and (val.i64 == '\n' or val.i64 == '\t')) continue;
                            is_str = false;
                            break;
                        }
                    }
                    if (is_str and len > 0) {
                        var sbuf: std.ArrayList(u8) = .empty;
                        defer sbuf.deinit(self.vm.allocator);
                        i = 0;
                        while (i < len) : (i += 1) {
                            try sbuf.append(self.vm.allocator, @intCast(self.vm.slot(p + @as(i32, @intCast(i))).*.i64));
                        }
                        if (self.flags.sharp_v) {
                            try self.formatString(sbuf.items, 'q');
                        } else {
                            try self.formatString(sbuf.items, 's');
                        }
                        return;
                    }
                    var sbuf: std.ArrayList(u8) = .empty;
                    defer sbuf.deinit(self.vm.allocator);
                    var sub_fmt = Formatter.init(self.vm, &sbuf);
                    sub_fmt.flags = self.flags;
                    try sbuf.append(self.vm.allocator, '{');
                    i = 0;
                    while (i < len) : (i += 1) {
                        if (i > 0) try sbuf.append(self.vm.allocator, ' ');
                        try sub_fmt.formatValue(self.vm.slot(p + @as(i32, @intCast(i))).*, 'v', depth + 1);
                    }
                    try sbuf.append(self.vm.allocator, '}');
                    try self.padBytes(sbuf.items);
                    return;
                }
                try self.formatPointer(p);
            },
            .function => |f| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "<fn {s}>", .{f.name});
                try self.padBytes(s);
            },
            .native => |n| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "<native {s}>", .{n.name});
                try self.padBytes(s);
            },
            .module => |m| {
                var buf: [128]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "<module {s}>", .{m.name});
                try self.padBytes(s);
            },
            .list => |l| {
                var lbuf: std.ArrayList(u8) = .empty;
                defer lbuf.deinit(self.vm.allocator);
                var sub_fmt = Formatter.init(self.vm, &lbuf);
                sub_fmt.flags = self.flags;
                try lbuf.append(self.vm.allocator, '[');
                var i: u32 = 0;
                while (i < l.items.count) : (i += 1) {
                    if (i > 0) try lbuf.append(self.vm.allocator, ' ');
                    const elem = self.vm.arrayElemConst(l.items, i);
                    try sub_fmt.formatValue(elem, 'v', depth + 1);
                }
                try lbuf.append(self.vm.allocator, ']');
                try self.padBytes(lbuf.items);
            },
            .map => |m| {
                var mbuf: std.ArrayList(u8) = .empty;
                defer mbuf.deinit(self.vm.allocator);
                var sub_fmt = Formatter.init(self.vm, &mbuf);
                sub_fmt.flags = self.flags;
                try mbuf.appendSlice(self.vm.allocator, "map[");
                var i: u32 = 0;
                while (i < m.keys.count) : (i += 1) {
                    if (i > 0) try mbuf.append(self.vm.allocator, ' ');
                    const k = self.vm.arrayElemConst(m.keys, i);
                    const val = self.vm.arrayElemConst(m.values, i);
                    try sub_fmt.formatValue(k, 'v', depth + 1);
                    try mbuf.append(self.vm.allocator, ':');
                    try sub_fmt.formatValue(val, 'v', depth + 1);
                }
                try mbuf.append(self.vm.allocator, ']');
                try self.padBytes(mbuf.items);
            },
            .buffer => |b| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "<Buffer {d} bytes>", .{b.data.len});
                try self.padBytes(s);
            },
        }
    }
};

fn parseDecInt(s: []const u8, idx: *usize) ?i32 {
    var val: i32 = 0;
    var found = false;
    while (idx.* < s.len and s[idx.*] >= '0' and s[idx.*] <= '9') {
        found = true;
        val = val * 10 + @as(i32, @intCast(s[idx.*] - '0'));
        idx.* += 1;
    }
    return if (found) val else null;
}

pub fn doPrintf(vm: *VMState, out: *std.ArrayList(u8), format: []const u8, args: []const Value) !void {
    // Check if format string is using legacy {s} / {i} / {c} placeholders without '%'
    if (std.mem.indexOfScalar(u8, format, '%') == null and
        (std.mem.indexOf(u8, format, "{s}") != null or std.mem.indexOf(u8, format, "{i}") != null or std.mem.indexOf(u8, format, "{c}") != null))
    {
        try doLegacyPrintf(vm, out, format, args);
        return;
    }

    var fmt = Formatter.init(vm, out);
    var arg_idx: usize = 0;
    var i: usize = 0;
    const len = format.len;
    var reordered = false;

    while (i < len) {
        if (format[i] != '%') {
            const start = i;
            while (i < len and format[i] != '%') : (i += 1) {}
            try out.appendSlice(vm.allocator, format[start..i]);
            continue;
        }

        i += 1; // skip '%'
        if (i >= len) {
            try out.appendSlice(vm.allocator, "%!(NOVERB)");
            break;
        }

        if (format[i] == '%') {
            try out.append(vm.allocator, '%');
            i += 1;
            continue;
        }

        fmt.flags.clear();

        // 1. Parse flags
        while (i < len) {
            switch (format[i]) {
                '+' => fmt.flags.plus = true,
                '-' => fmt.flags.minus = true,
                '#' => fmt.flags.sharp = true,
                ' ' => fmt.flags.space = true,
                '0' => fmt.flags.zero = true,
                else => break,
            }
            i += 1;
        }

        // 2. Parse argument index if present: %[1]d
        var explicit_idx: ?usize = null;
        if (i < len and format[i] == '[') {
            i += 1;
            if (parseDecInt(format, &i)) |num| {
                if (i < len and format[i] == ']') {
                    i += 1;
                    if (num > 0) {
                        explicit_idx = @intCast(num - 1);
                        reordered = true;
                    }
                }
            }
        }

        // 3. Parse width
        if (i < len and format[i] == '*') {
            i += 1;
            if (arg_idx < args.len) {
                const w = widths.valueAsI64(args[arg_idx]) orelse 0;
                arg_idx += 1;
                if (w < 0) {
                    fmt.flags.wid = @intCast(-w);
                    fmt.flags.minus = true;
                } else {
                    fmt.flags.wid = @intCast(w);
                }
                fmt.flags.wid_present = true;
            } else {
                try out.appendSlice(vm.allocator, "%!(BADWIDTH)");
            }
        } else if (parseDecInt(format, &i)) |w| {
            fmt.flags.wid = w;
            fmt.flags.wid_present = true;
        }

        // 4. Parse precision
        if (i < len and format[i] == '.') {
            i += 1;
            fmt.flags.prec_present = true;
            if (i < len and format[i] == '*') {
                i += 1;
                if (arg_idx < args.len) {
                    const p = widths.valueAsI64(args[arg_idx]) orelse 0;
                    arg_idx += 1;
                    if (p >= 0) {
                        fmt.flags.prec = @intCast(p);
                    } else {
                        fmt.flags.prec_present = false;
                    }
                } else {
                    try out.appendSlice(vm.allocator, "%!(BADPREC)");
                }
            } else if (parseDecInt(format, &i)) |p| {
                fmt.flags.prec = p;
            } else {
                fmt.flags.prec = 0;
            }
        }

        // Check for index again if placed after width/prec
        if (i < len and format[i] == '[') {
            i += 1;
            if (parseDecInt(format, &i)) |num| {
                if (i < len and format[i] == ']') {
                    i += 1;
                    if (num > 0) {
                        explicit_idx = @intCast(num - 1);
                        reordered = true;
                    }
                }
            }
        }

        if (i >= len) {
            try out.appendSlice(vm.allocator, "%!(NOVERB)");
            break;
        }

        const verb = format[i];
        i += 1;

        if (verb == 'v') {
            if (fmt.flags.plus) {
                fmt.flags.plus_v = true;
                fmt.flags.plus = false;
            }
            if (fmt.flags.sharp) {
                fmt.flags.sharp_v = true;
                fmt.flags.sharp = false;
            }
        }

        const current_idx = explicit_idx orelse arg_idx;
        if (explicit_idx == null) arg_idx += 1;

        if (current_idx >= args.len) {
            try out.appendSlice(vm.allocator, "%!");
            try out.append(vm.allocator, verb);
            try out.appendSlice(vm.allocator, "(MISSING)");
            continue;
        }

        try fmt.formatValue(args[current_idx], verb, 0);
    }

    if (!reordered and arg_idx < args.len) {
        try out.appendSlice(vm.allocator, "%!(EXTRA ");
        var first = true;
        while (arg_idx < args.len) : (arg_idx += 1) {
            if (!first) try out.appendSlice(vm.allocator, ", ");
            first = false;
            try fmt.formatTypeName(args[arg_idx]);
            try out.append(vm.allocator, '=');
            fmt.flags.clear();
            try fmt.formatValue(args[arg_idx], 'v', 0);
        }
        try out.append(vm.allocator, ')');
    }
}

fn doLegacyPrintf(vm: *VMState, out: *std.ArrayList(u8), format: []const u8, args: []const Value) !void {
    var cur = try vm.allocator.dupe(u8, format);
    defer vm.allocator.free(cur);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const idx_s = std.mem.indexOf(u8, cur, "{s}");
        const idx_i = std.mem.indexOf(u8, cur, "{i}");
        const idx_c = std.mem.indexOf(u8, cur, "{c}");

        var min_idx: ?usize = null;
        var placeholder: enum { s, i, c } = .s;
        if (idx_s) |pos| { min_idx = pos; placeholder = .s; }
        if (idx_i) |pos| {
            if (min_idx == null or pos < min_idx.?) { min_idx = pos; placeholder = .i; }
        }
        if (idx_c) |pos| {
            if (min_idx == null or pos < min_idx.?) { min_idx = pos; placeholder = .c; }
        }

        if (min_idx == null) break;

        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(vm.allocator);
        var fmt = Formatter.init(vm, &val_buf);

        switch (placeholder) {
            .s => {
                var sbuf: std.ArrayList(u8) = .empty;
                defer sbuf.deinit(vm.allocator);
                if (args[i] == .name or args[i] == .slice or args[i] == .bytes) {
                    const s = try util.valueToStr(vm, args[i], &sbuf);
                    try val_buf.appendSlice(vm.allocator, s);
                } else {
                    try fmt.formatValue(args[i], 'v', 0);
                }
            },
            .i => {
                const n = widths.valueAsI64(args[i]) orelse 0;
                try fmt.formatInteger(@bitCast(n), true, 10, false, 'd');
            },
            .c => {
                const n = widths.valueAsI64(args[i]) orelse 0;
                try fmt.formatRune(@intCast(n));
            },
        }

        const tag = switch (placeholder) {
            .s => "{s}",
            .i => "{i}",
            .c => "{c}",
        };

        if (std.mem.indexOf(u8, cur, tag)) |pos| {
            const new_cur = try std.mem.concat(vm.allocator, u8, &.{
                cur[0..pos],
                val_buf.items,
                cur[pos + tag.len ..],
            });
            vm.allocator.free(cur);
            cur = new_cur;
        }
    }
    try out.appendSlice(vm.allocator, cur);
}

pub fn doPrint(vm: *VMState, out: *std.ArrayList(u8), args: []const Value) !void {
    var fmt = Formatter.init(vm, out);
    var prev_string = false;
    for (args, 0..) |arg, idx| {
        const is_string = (arg == .name or arg == .slice);
        if (idx > 0 and !is_string and !prev_string) {
            try out.append(vm.allocator, ' ');
        }
        fmt.flags.clear();
        try fmt.formatValue(arg, 'v', 0);
        prev_string = is_string;
    }
}

pub fn doPrintln(vm: *VMState, out: *std.ArrayList(u8), args: []const Value) !void {
    var fmt = Formatter.init(vm, out);
    for (args, 0..) |arg, idx| {
        if (idx > 0) try out.append(vm.allocator, ' ');
        fmt.flags.clear();
        try fmt.formatValue(arg, 'v', 0);
    }
    try out.append(vm.allocator, '\n');
}

fn extractArgs(vm: *VMState, args: []Value, start: usize, arena: *std.ArrayList(Value)) ![]const Value {
    if (args.len <= start) return &.{};
    if (args.len == start + 1 and args[start] == .array) {
        const arr = args[start].array;
        try arena.ensureTotalCapacity(vm.allocator, arr.count);
        var j: u32 = 0;
        while (j < arr.count) : (j += 1) {
            arena.appendAssumeCapacity(vm.arrayElemConst(arr, j));
        }
        return arena.items;
    }
    return args[start..];
}

fn sprintfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;

    var fmt_buf: std.ArrayList(u8) = .empty;
    defer fmt_buf.deinit(vm.allocator);
    const fmt_str = try util.valueToStr(vm, args[0], &fmt_buf);

    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const fmt_args = try extractArgs(vm, args, 1, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrintf(vm, &out, fmt_str, fmt_args);
    return util.writeSlice(vm, out.items);
}

fn printfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;

    var fmt_buf: std.ArrayList(u8) = .empty;
    defer fmt_buf.deinit(vm.allocator);
    const fmt_str = try util.valueToStr(vm, args[0], &fmt_buf);

    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const fmt_args = try extractArgs(vm, args, 1, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrintf(vm, &out, fmt_str, fmt_args);
    out_mod.writeStdout(out.items);
    return .{ .i64 = @intCast(out.items.len) };
}

fn fprintfFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 2) return error.ArityError;

    const fd: std.posix.fd_t = @intCast(widths.valueAsI64(args[0]) orelse 1);

    var fmt_buf: std.ArrayList(u8) = .empty;
    defer fmt_buf.deinit(vm.allocator);
    const fmt_str = try util.valueToStr(vm, args[1], &fmt_buf);

    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const fmt_args = try extractArgs(vm, args, 2, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrintf(vm, &out, fmt_str, fmt_args);
    const written = std.posix.write(fd, out.items) catch 0;
    return .{ .i64 = @intCast(written) };
}

fn sprintFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const print_args = try extractArgs(vm, args, 0, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrint(vm, &out, print_args);
    return util.writeSlice(vm, out.items);
}

fn sprintlnFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const print_args = try extractArgs(vm, args, 0, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrintln(vm, &out, print_args);
    return util.writeSlice(vm, out.items);
}

fn fprintFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(widths.valueAsI64(args[0]) orelse 1);

    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const print_args = try extractArgs(vm, args, 1, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrint(vm, &out, print_args);
    const written = std.posix.write(fd, out.items) catch 0;
    return .{ .i64 = @intCast(written) };
}

fn fprintlnFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;
    const fd: std.posix.fd_t = @intCast(widths.valueAsI64(args[0]) orelse 1);

    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const print_args = try extractArgs(vm, args, 1, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrintln(vm, &out, print_args);
    const written = std.posix.write(fd, out.items) catch 0;
    return .{ .i64 = @intCast(written) };
}

pub fn printLnFn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VMState = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1) return error.ArityError;

    var fmt_buf: std.ArrayList(u8) = .empty;
    defer fmt_buf.deinit(vm.allocator);
    const fmt_str = try util.valueToStr(vm, args[0], &fmt_buf);

    var unpacked: std.ArrayList(Value) = .empty;
    defer unpacked.deinit(vm.allocator);
    const fmt_args = try extractArgs(vm, args, 1, &unpacked);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);

    try doPrintf(vm, &out, fmt_str, fmt_args);
    try out.append(vm.allocator, '\n');
    out_mod.writeStdout(out.items);
    return .null;
}

var sprintf_native: NativeFunction = undefined;
var printf_native: NativeFunction = undefined;
var fprintf_native: NativeFunction = undefined;
var sprint_native: NativeFunction = undefined;
var sprintln_native: NativeFunction = undefined;
var fprint_native: NativeFunction = undefined;
var fprintln_native: NativeFunction = undefined;
var print_ln_native: NativeFunction = undefined;

pub fn register(vm: *VMState) !void {
    sprintf_native = .{ .name = "__sprintf", .func = sprintfFn, .arity = -1 };
    try vm.defineGlobal("__sprintf", .{ .native = &sprintf_native });

    printf_native = .{ .name = "__printf", .func = printfFn, .arity = -1 };
    try vm.defineGlobal("__printf", .{ .native = &printf_native });

    fprintf_native = .{ .name = "__fprintf", .func = fprintfFn, .arity = -1 };
    try vm.defineGlobal("__fprintf", .{ .native = &fprintf_native });

    sprint_native = .{ .name = "__sprint", .func = sprintFn, .arity = -1 };
    try vm.defineGlobal("__sprint", .{ .native = &sprint_native });

    sprintln_native = .{ .name = "__sprintln", .func = sprintlnFn, .arity = -1 };
    try vm.defineGlobal("__sprintln", .{ .native = &sprintln_native });

    fprint_native = .{ .name = "__fprint", .func = fprintFn, .arity = -1 };
    try vm.defineGlobal("__fprint", .{ .native = &fprint_native });

    fprintln_native = .{ .name = "__fprintln", .func = fprintlnFn, .arity = -1 };
    try vm.defineGlobal("__fprintln", .{ .native = &fprintln_native });

    print_ln_native = .{ .name = "__printLn", .func = printLnFn, .arity = -1 };
    try vm.defineGlobal("__printLn", .{ .native = &print_ln_native });
}
