//! Native string functions backing `std/string.lls` (mirrors
//! `src/vm/builtins/string.zig`). Native strings are C strings; results are
//! copied into the runtime string heap (see `util.zig`).

const std = @import("std");
const util = @import("util.zig");

const cstr = util.cstr;
const dupBytes = util.dupBytes;
const strAlloc = util.strAlloc;
const countPrefixedStrings = util.countPrefixedStrings;

export fn __substr(s: [*:0]const u8, start: i64, len: i64) [*:0]u8 {
    const str = cstr(s);
    const bs: usize = @intCast(@max(start, 0));
    const bl: usize = @intCast(@max(len, 0));
    const bounded_start = @min(bs, str.len);
    const bounded_len = @min(bl, str.len - bounded_start);
    if (bounded_start >= str.len) return dupBytes("");
    return dupBytes(str[bounded_start .. bounded_start + bounded_len]);
}

export fn __indexOf(s: [*:0]const u8, search: [*:0]const u8) i64 {
    const str = cstr(s);
    if (std.mem.indexOf(u8, str, cstr(search))) |idx| return @intCast(idx);
    return -1;
}

export fn __lastIndexOf(s: [*:0]const u8, search: [*:0]const u8) i64 {
    const str = cstr(s);
    if (std.mem.lastIndexOf(u8, str, cstr(search))) |idx| return @intCast(idx);
    return -1;
}

export fn __indexOfFrom(s: [*:0]const u8, search: [*:0]const u8, from: i64) i64 {
    const str = cstr(s);
    const start: usize = @intCast(@max(from, 0));
    if (start >= str.len) return -1;
    if (std.mem.indexOfPos(u8, str, start, cstr(search))) |idx| return @intCast(idx);
    return -1;
}

export fn __contains(s: [*:0]const u8, search: [*:0]const u8) bool {
    return std.mem.indexOf(u8, cstr(s), cstr(search)) != null;
}

export fn __startsWith(s: [*:0]const u8, prefix: [*:0]const u8) bool {
    return std.mem.startsWith(u8, cstr(s), cstr(prefix));
}

export fn __endsWith(s: [*:0]const u8, suffix: [*:0]const u8) bool {
    return std.mem.endsWith(u8, cstr(s), cstr(suffix));
}

fn mapCase(s: [*:0]const u8, upper: bool) [*:0]u8 {
    const str = cstr(s);
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, str.len, 0) catch @panic("native OOM");
    for (str, 0..) |c, i| {
        buf[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
    }
    return buf.ptr;
}

export fn __toUpper(s: [*:0]const u8) [*:0]u8 {
    return mapCase(s, true);
}

export fn __toLower(s: [*:0]const u8) [*:0]u8 {
    return mapCase(s, false);
}

export fn __trim(s: [*:0]const u8) [*:0]u8 {
    return dupBytes(std.mem.trim(u8, cstr(s), &std.ascii.whitespace));
}

export fn __trimStart(s: [*:0]const u8) [*:0]u8 {
    return dupBytes(std.mem.trimLeft(u8, cstr(s), &std.ascii.whitespace));
}

export fn __trimEnd(s: [*:0]const u8) [*:0]u8 {
    return dupBytes(std.mem.trimRight(u8, cstr(s), &std.ascii.whitespace));
}

export fn __replace(s: [*:0]const u8, search: [*:0]const u8, repl: [*:0]const u8) [*:0]u8 {
    const str = cstr(s);
    const needle = cstr(search);
    const out_len = std.mem.replacementSize(u8, str, needle, cstr(repl));
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, out_len, 0) catch @panic("native OOM");
    _ = std.mem.replace(u8, str, needle, cstr(repl), buf[0..out_len]);
    return buf.ptr;
}

export fn __replaceFirst(s: [*:0]const u8, search: [*:0]const u8, repl: [*:0]const u8) [*:0]u8 {
    const str = cstr(s);
    const needle = cstr(search);
    if (std.mem.indexOf(u8, str, needle)) |idx| {
        const out_len = str.len - needle.len + cstr(repl).len;
        const alloc = strAlloc();
        const buf = alloc.allocSentinel(u8, out_len, 0) catch @panic("native OOM");
        @memcpy(buf[0..idx], str[0..idx]);
        @memcpy(buf[idx .. idx + cstr(repl).len], cstr(repl));
        @memcpy(buf[idx + cstr(repl).len .. out_len], str[idx + needle.len ..]);
        return buf.ptr;
    }
    return dupBytes(str);
}

export fn __concat(a: [*:0]const u8, b: [*:0]const u8) [*:0]u8 {
    const sa = cstr(a);
    const sb = cstr(b);
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, sa.len + sb.len, 0) catch @panic("native OOM");
    @memcpy(buf[0..sa.len], sa);
    @memcpy(buf[sa.len .. sa.len + sb.len], sb);
    return buf.ptr;
}

export fn __repeat(s: [*:0]const u8, count: i64) [*:0]u8 {
    const str = cstr(s);
    const n: usize = @intCast(@max(count, 0));
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, str.len * n, 0) catch @panic("native OOM");
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(buf[i * str.len .. (i + 1) * str.len], str);
    return buf.ptr;
}

export fn __charCodeAt(s: [*:0]const u8, index: i64) i64 {
    const str = cstr(s);
    const i: usize = @intCast(@max(index, 0));
    if (i >= str.len) return -1;
    return str[i];
}

export fn __parseInt(s: [*:0]const u8, base: i64) i64 {
    const b: u8 = @intCast(@max(base, 2));
    const v = std.fmt.parseInt(i64, cstr(s), b) catch return 0;
    return v;
}

export fn __parseFloat(s: [*:0]const u8) f64 {
    const v = std.fmt.parseFloat(f64, cstr(s)) catch return std.math.nan(f64);
    return v;
}

export fn __fromCharCode(code: i64) ?[*:0]u8 {
    if (code < 0 or code > 255) return @ptrFromInt(util.errNewAddr(util.dupBytes("InvalidCharCode"), 0));
    const c: u8 = @intCast(code);
    return dupBytes(&[_]u8{c});
}

export fn __slice(s: [*:0]const u8, start: i64, end: i64) [*:0]u8 {
    const str = cstr(s);
    const str_len: i64 = @intCast(str.len);
    var start_idx = start;
    if (start_idx < 0) {
        start_idx = @max(str_len + start_idx, 0);
    } else {
        start_idx = @min(start_idx, str_len);
    }
    var end_idx = end;
    if (end_idx < 0) {
        end_idx = @max(str_len + end_idx, 0);
    } else {
        end_idx = @min(end_idx, str_len);
    }
    if (start_idx >= end_idx) return dupBytes("");
    const st: usize = @intCast(start_idx);
    const en: usize = @intCast(end_idx);
    return dupBytes(str[st..en]);
}

export fn __compare(a: [*:0]const u8, b: [*:0]const u8) i64 {
    return switch (std.mem.order(u8, cstr(a), cstr(b))) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

export fn __eql(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.eql(u8, cstr(a), cstr(b));
}

export fn __split(s: [*:0]const u8, sep: [*:0]const u8) [*]const u8 {
    const str = cstr(s);
    const needle = cstr(sep);
    var parts: std.ArrayList([*:0]const u8) = .empty;
    defer parts.deinit(strAlloc());
    if (needle.len == 0) {
        for (str) |ch| {
            parts.append(strAlloc(), dupBytes(&[_]u8{ch})) catch @panic("native OOM");
        }
    } else {
        var it = std.mem.splitSequence(u8, str, needle);
        while (it.next()) |part| parts.append(strAlloc(), dupBytes(part)) catch @panic("native OOM");
    }
    return countPrefixedStrings(parts.items);
}

export fn __splitMax(s: [*:0]const u8, sep: [*:0]const u8, limit: i64) [*]const u8 {
    const str = cstr(s);
    const needle = cstr(sep);
    var parts: std.ArrayList([*:0]const u8) = .empty;
    defer parts.deinit(strAlloc());
    if (limit == 0) return countPrefixedStrings(parts.items);
    if (needle.len == 0) {
        var count: i64 = 0;
        var i: usize = 0;
        while (i < str.len and count < limit - 1) : (i += 1) {
            parts.append(strAlloc(), dupBytes(&[_]u8{str[i]})) catch @panic("native OOM");
            count += 1;
        }
        parts.append(strAlloc(), dupBytes(str[i..])) catch @panic("native OOM");
    } else {
        var count: i64 = 0;
        var start: usize = 0;
        while (count < limit - 1) {
            if (std.mem.indexOfPos(u8, str, start, needle)) |idx| {
                parts.append(strAlloc(), dupBytes(str[start..idx])) catch @panic("native OOM");
                start = idx + needle.len;
                count += 1;
            } else break;
        }
        parts.append(strAlloc(), dupBytes(str[start..])) catch @panic("native OOM");
    }
    return countPrefixedStrings(parts.items);
}

export fn __join(arr: [*]align(8) const u8, sep: [*:0]const u8) [*:0]u8 {
    const slots: [*]const usize = @ptrCast(arr);
    const count = slots[~@as(usize, 0)];
    const items: [*]const [*:0]const u8 = @ptrCast(slots);
    if (count == 0) return dupBytes("");
    var total: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        total += cstr(items[i]).len;
        if (i + 1 < count) total += cstr(sep).len;
    }
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, total, 0) catch @panic("native OOM");
    var off: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const it = cstr(items[i]);
        @memcpy(buf[off .. off + it.len], it);
        off += it.len;
        if (i + 1 < count) {
            const sp = cstr(sep);
            @memcpy(buf[off .. off + sp.len], sp);
            off += sp.len;
        }
    }
    return buf.ptr;
}

export fn __padStart(s: [*:0]const u8, target_len: i64, pad: [*:0]const u8) [*:0]u8 {
    return padImpl(s, target_len, pad, true);
}

export fn __padEnd(s: [*:0]const u8, target_len: i64, pad: [*:0]const u8) [*:0]u8 {
    return padImpl(s, target_len, pad, false);
}

fn padImpl(s: [*:0]const u8, target_len: i64, pad: [*:0]const u8, start: bool) [*:0]u8 {
    const str = cstr(s);
    const target: usize = @intCast(@max(target_len, 0));
    const p = cstr(pad);
    if (str.len >= target or p.len == 0) return dupBytes(str);
    const pad_needed = target - str.len;
    const alloc = strAlloc();
    const buf = alloc.allocSentinel(u8, target, 0) catch @panic("native OOM");
    const pad_part = blk: {
        const out = alloc.alloc(u8, pad_needed) catch @panic("native OOM");
        var written: usize = 0;
        while (written < pad_needed) {
            const take = @min(p.len, pad_needed - written);
            @memcpy(out[written .. written + take], p[0..take]);
            written += take;
        }
        break :blk out;
    };
    if (start) {
        @memcpy(buf[0..pad_needed], pad_part);
        @memcpy(buf[pad_needed..target], str);
    } else {
        @memcpy(buf[0..str.len], str);
        @memcpy(buf[str.len..target], pad_part);
    }
    return buf.ptr;
}

export fn __isEmpty(s: [*:0]const u8) bool {
    return cstr(s).len == 0;
}

export fn __isBlank(s: [*:0]const u8) bool {
    return std.mem.trim(u8, cstr(s), &std.ascii.whitespace).len == 0;
}
