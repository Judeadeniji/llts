//! Native runtime unit tests — semantics and trap messages verified against
//! the VM oracles (`src/vm/execute/arith.zig`, `compare.zig`,
//! `src/vm/builtins/print.zig`, `src/errors/stack_trace.zig`).

const std = @import("std");
const testing = std.testing;
const rt = @import("runtime");
const arith = rt.arith;
const mem = rt.mem;
const print = rt.print;
const err = rt.err;
const Context = rt.Context;
const io = rt.io;
const trace = rt.trace;

// --- arith: overflow message format (VM byte-exact) ------------------------

test "arith: overflow messages match VM exactly" {
    var buf: [192]u8 = undefined;
    const add_msg = try arith.formatOverflow(&buf, .add, "i64");
    try testing.expectEqualStrings(
        "Integer overflow: addition exceeds 'i64'; did you mean '+%'?",
        add_msg,
    );
    const sub_msg = try arith.formatOverflow(&buf, .sub, "i64");
    try testing.expectEqualStrings(
        "Integer overflow: subtraction exceeds 'i64'; did you mean '-%'?",
        sub_msg,
    );
    const mul_msg = try arith.formatOverflow(&buf, .mul, "u8");
    try testing.expectEqualStrings(
        "Integer overflow: multiplication exceeds 'u8'; did you mean '*%'?",
        mul_msg,
    );
    // Division has no wrapping alternative to suggest.
    const div_msg = try arith.formatOverflow(&buf, .div, "i64");
    try testing.expectEqualStrings("Integer overflow: division exceeds 'i64'", div_msg);
}

test "arith: shift range message matches VM exactly" {
    var buf: [64]u8 = undefined;
    const msg = try arith.formatShiftOutOfRange(&buf, 64);
    try testing.expectEqualStrings("Shift amount out of range 0..63 (got 64)", msg);
    const neg = try arith.formatShiftOutOfRange(&buf, -1);
    try testing.expectEqualStrings("Shift amount out of range 0..63 (got -1)", neg);
}

// --- arith: i64 checked / wrapping -----------------------------------------

test "arith: checked add/sub/mul trap on overflow" {
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.add(std.math.maxInt(i64), 1));
    try testing.expectError(error.RuntimeError, arith.add(std.math.minInt(i64), -1));
    try testing.expectError(error.RuntimeError, arith.sub(std.math.minInt(i64), 1));
    try testing.expectError(error.RuntimeError, arith.sub(std.math.maxInt(i64), -1));
    try testing.expectError(error.RuntimeError, arith.mul(std.math.maxInt(i64), 2));
    try testing.expectError(error.RuntimeError, arith.mul(std.math.minInt(i64), -1));
}

test "arith: checked add/sub/mul exact at the boundary" {
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try arith.add(std.math.maxInt(i64) - 1, 1));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try arith.add(std.math.minInt(i64) + 1, -1));
    // 0 - (minInt+1) = maxInt — fits, no trap.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), arith.sub(0, std.math.minInt(i64) + 1) catch unreachable);
    // 0 - minInt would be minInt's negation — overflow, traps.
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.sub(0, std.math.minInt(i64)));
}

test "arith: wrapping add/sub/mul" {
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), arith.addWrap(std.math.maxInt(i64), 1));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), arith.addWrap(std.math.minInt(i64), -1));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), arith.subWrap(std.math.minInt(i64), 1));
    // 0 -% minInt = minInt (negating minInt wraps to itself).
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), arith.subWrap(0, std.math.minInt(i64)));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), arith.mulWrap(std.math.minInt(i64), -1));
    try testing.expectEqual(@as(i64, 6), arith.mulWrap(2, 3));
}

test "arith: div/rem semantics" {
    try testing.expectEqual(@as(i64, 3), try arith.div(7, 2));
    try testing.expectEqual(@as(i64, -3), try arith.div(-7, 2)); // @divTrunc
    try testing.expectEqual(@as(i64, -3), try arith.div(7, -2));
    try testing.expectEqual(@as(i64, 3), try arith.div(-7, -2));
    try testing.expectEqual(@as(i64, 1), try arith.rem(7, 3));
    try testing.expectEqual(@as(i64, -1), try arith.rem(-7, 3)); // @rem keeps dividend sign
    try testing.expectEqual(@as(i64, 1), try arith.rem(7, -3));
}

test "arith: div/rem traps" {
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.div(1, 0));
    try testing.expectError(error.RuntimeError, arith.rem(1, 0));
    try testing.expectError(error.RuntimeError, arith.div(std.math.minInt(i64), -1));
}

test "arith: pow" {
    try testing.expectEqual(@as(i64, 1024), arith.pow(2, 10));
    try testing.expectEqual(@as(i64, 1), arith.pow(0, 0));
    try testing.expectEqual(@as(i64, 0), arith.pow(0, 5));
    try testing.expectEqual(@as(i64, 0), arith.pow(5, -1)); // negative exp → 0
    // Wrapping: large powers wrap via *%.
    const big = arith.pow(2, 62);
    try testing.expectEqual(@as(i64, 1 << 62), big);
    const wrapped = arith.pow(2, 63);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), wrapped);
}

test "arith: neg" {
    try testing.expectEqual(@as(i64, -5), try arith.neg(5));
    try testing.expectEqual(@as(i64, 5), try arith.neg(-5));
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.neg(std.math.minInt(i64)));
}

test "arith: shifts" {
    try testing.expectEqual(@as(i64, 1024), try arith.shl(1, 10));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try arith.shl(1, 63)); // bit 63 set
    try testing.expectEqual(@as(i64, -1), try arith.shr(std.math.minInt(i64), 63)); // arithmetic
    try testing.expectEqual(@as(i64, -4), try arith.shr(-8, 1)); // arithmetic
    try testing.expectEqual(@as(i64, 4), try arith.shr(8, 1));
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.shl(1, 64));
    try testing.expectError(error.RuntimeError, arith.shl(1, -1));
    try testing.expectError(error.RuntimeError, arith.shr(1, 64));
}

test "arith: bitwise" {
    try testing.expectEqual(@as(i64, 0b1000), arith.band(0b1100, 0b1010));
    try testing.expectEqual(@as(i64, 0b1110), arith.bor(0b1100, 0b1010));
    try testing.expectEqual(@as(i64, 0b0110), arith.bxor(0b1100, 0b1010));
    try testing.expectEqual(@as(i64, ~@as(i64, 0)), arith.bnot(0));
}

// --- arith: typed ops -------------------------------------------------------

test "arith: typed checked traps at declared width" {
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.addChecked(.i8, 100, 30)); // 130 > 127
    try testing.expectError(error.RuntimeError, arith.addChecked(.i8, -120, -10));
    try testing.expectError(error.RuntimeError, arith.subChecked(.u8, 0, 1));
    try testing.expectError(error.RuntimeError, arith.mulChecked(.u8, 200, 2));
    try testing.expectError(error.RuntimeError, arith.addChecked(.i64, std.math.maxInt(i64), 1));
    try testing.expectError(error.RuntimeError, arith.addChecked(.isize, std.math.maxInt(i64), 1));
}

test "arith: typed wrap truncates to width" {
    try testing.expectEqual(@as(i64, -126), arith.addWrapped(.i8, 100, 30)); // 130 as i8
    try testing.expectEqual(@as(i64, 44), arith.addWrapped(.u8, 200, 100)); // 300 & 0xff
    try testing.expectEqual(@as(i64, 0xff), arith.subWrapped(.u8, 0, 1));
    try testing.expectEqual(@as(i64, -1), arith.subWrapped(.i16, 0, 1));
    // i16 mul wrap: 200 * 200 = 40000 → low 16 bits = 40000 - 65536 = -25536
    try testing.expectEqual(@as(i64, -25536), arith.mulWrapped(.i16, 200, 200));
    // i64 fast path
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), arith.addWrapped(.i64, std.math.maxInt(i64), 1));
}

test "arith: typed within-range results" {
    try testing.expectEqual(@as(i64, 127), try arith.addChecked(.i8, 100, 27));
    try testing.expectEqual(@as(i64, -128), try arith.addChecked(.i8, -100, -28));
    try testing.expectEqual(@as(i64, 255), try arith.addChecked(.u8, 200, 55));
    try testing.expectEqual(@as(i64, 0), try arith.subChecked(.u8, 0, 0));
}

test "arith: ltWidth" {
    try testing.expect(arith.ltWidth(.i64, 1, 2));
    try testing.expect(!arith.ltWidth(.i64, 2, 1));
    try testing.expect(!arith.ltWidth(.i64, 2, 2));
    try testing.expect(arith.ltWidth(.i8, -5, 5));
}

// --- arith: floats ----------------------------------------------------------

test "arith: f64 semantics" {
    try testing.expectEqual(@as(f64, 4.5), arith.addF64(2.0, 2.5));
    try testing.expectEqual(@as(f64, -0.5), arith.subF64(2.0, 2.5));
    try testing.expectEqual(@as(f64, 5.0), arith.mulF64(2.0, 2.5));
    try testing.expectEqual(@as(f64, 0.5), try arith.divF64(1.0, 2.0));
    try testing.expectEqual(@as(f64, 1024.0), arith.powF64(2.0, 10.0));
    try testing.expectEqual(@as(f64, -3.5), arith.negF64(3.5));
    // mod is @mod (floored), not @rem.
    try testing.expectEqual(@as(f64, 0.5), try arith.modF64(-7.5, 2.0));
    try testing.expectEqual(@as(f64, 1.0), try arith.modF64(7.0, 2.0));
}

test "arith: f64 div/mod trap on zero" {
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.divF64(1.0, 0.0));
    try testing.expectError(error.RuntimeError, arith.modF64(1.0, 0.0));
}

test "arith: f32 preserved" {
    try testing.expectEqual(@as(f32, 4.5), arith.addF32(2.0, 2.5));
    try testing.expectEqual(@as(f32, 0.5), try arith.divF32(1.0, 2.0));
    try testing.expectEqual(@as(f32, 1.25), arith.mulF32(2.5, 0.5));
    try testing.expectEqual(@as(f32, 1024.0), arith.powF32(2.0, 10.0));
    rt.io.silence_stderr = true;
    defer rt.io.silence_stderr = false;
    try testing.expectError(error.RuntimeError, arith.divF32(1.0, 0.0));
    try testing.expectError(error.RuntimeError, arith.modF32(1.0, 0.0));
}

// --- arith: comparisons -----------------------------------------------------

test "arith: comparisons" {
    try testing.expect(arith.ltI64(1, 2));
    try testing.expect(arith.leI64(2, 2));
    try testing.expect(arith.gtI64(3, 2));
    try testing.expect(arith.geI64(2, 2));
    // Exact beyond 2^53 (VM untyped path loses this via f64 — native is exact).
    const big = @as(i64, 1) << 62;
    try testing.expect(arith.gtI64(big + 1, big));
    try testing.expect(arith.ltF64(1.5, 2.5));
    try testing.expect(arith.geF64(2.5, 2.5));
    try testing.expect(arith.ltF32(1.5, 2.5));
    try testing.expect(arith.eqI64(3, 3));
    try testing.expect(!arith.eqI64(3, 4));
    try testing.expect(arith.eqF64(2.5, 2.5));
    try testing.expect(arith.eqF64(0.0, -0.0)); // IEEE: -0 == 0
    try testing.expect(!arith.eqF64(std.math.nan(f64), std.math.nan(f64)));
    try testing.expect(arith.eqBool(true, true));
    try testing.expect(!arith.eqBool(true, false));
    try testing.expect(arith.eqStr("ab", "ab"));
    try testing.expect(!arith.eqStr("ab", "ac"));
    try testing.expect(arith.eqStr("", ""));
}

// --- context ----------------------------------------------------------------

test "context: init / alloc / leaveFrame rewind" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 1024,
        .immortal_capacity = 1024,
    });
    defer ctx.deinit();

    const mark = ctx.enterFrame();
    const a = try ctx.allocFrame(16, 8);
    try testing.expectEqual(@as(usize, 16), a.len);
    try testing.expectEqual(@as(usize, 16), ctx.frame_len);

    const b = try ctx.allocFrame(32, 8);
    try testing.expect(ctx.frame_len >= 48);
    _ = b;

    ctx.leaveFrame(mark);
    try testing.expectEqual(@as(usize, 0), ctx.frame_len);

    // Rewound space is reusable.
    const c = try ctx.allocFrame(64, 8);
    try testing.expectEqual(@as(usize, 64), c.len);
}

test "context: alignment" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 1024,
        .immortal_capacity = 64,
    });
    defer ctx.deinit();

    const a = try ctx.allocFrame(1, 8);
    const b = try ctx.allocFrame(1, 8);
    try testing.expectEqual(@as(usize, 8), @intFromPtr(b.ptr) - @intFromPtr(a.ptr));

    const c = try ctx.allocImmortal(1, 16);
    const d = try ctx.allocImmortal(1, 16);
    try testing.expectEqual(@as(usize, 16), @intFromPtr(d.ptr) - @intFromPtr(c.ptr));
}

test "context: immortal is never rewound" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 256,
        .immortal_capacity = 256,
    });
    defer ctx.deinit();

    const lit = try ctx.allocImmortal(5, 1);
    @memcpy(lit, "hello");

    const mark = ctx.enterFrame();
    const scratch = try ctx.allocFrame(32, 1);
    @memcpy(scratch[0..32], &[_]u8{0xAB} ** 32);
    ctx.leaveFrame(mark);

    // Immortal contents survive the frame exit.
    try testing.expectEqualStrings("hello", ctx.immortal[0..5]);
    try testing.expectEqual(@as(usize, 5), ctx.immortal_len);
}

test "context: exhaustion traps with OutOfMemory" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 16,
        .immortal_capacity = 8,
    });
    defer ctx.deinit();

    _ = try ctx.allocFrame(8, 1);
    try testing.expectError(error.OutOfMemory, ctx.allocFrame(16, 1));
    _ = try ctx.allocImmortal(8, 1);
    try testing.expectError(error.OutOfMemory, ctx.allocImmortal(1, 1));
}

test "context: default capacities match the plan" {
    try testing.expectEqual(@as(usize, 1024 * 1024 * 16), rt.context.DEFAULT_FRAME_CAPACITY);
    try testing.expectEqual(@as(usize, 1024 * 1024 * 16), rt.context.DEFAULT_IMMORTAL_CAPACITY);
}

// --- mem --------------------------------------------------------------------

test "mem: cloneBytes is a deep copy ([]byte value semantics)" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 1024,
        .immortal_capacity = 1024,
    });
    defer ctx.deinit();

    var src = [_]u8{ 'a', 'b', 'c' };
    const copy = try mem.cloneBytes(&ctx, &src);
    try testing.expectEqualStrings("abc", copy);

    // Mutating the source does not affect the clone — `$b = a` copies.
    src[0] = 'z';
    try testing.expectEqualStrings("abc", copy);
}

test "mem: concat lands in immortal and survives leaveFrame" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 256,
        .immortal_capacity = 256,
    });
    defer ctx.deinit();

    const mark = ctx.enterFrame();
    const joined = try mem.concat(&ctx, "Hello, ", "world");
    ctx.leaveFrame(mark);
    try testing.expectEqualStrings("Hello, world", joined);
}

test "mem: concat with empty operands" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 64,
        .immortal_capacity = 64,
    });
    defer ctx.deinit();
    try testing.expectEqualStrings("ab", try mem.concat(&ctx, "ab", ""));
    try testing.expectEqualStrings("ab", try mem.concat(&ctx, "", "ab"));
    try testing.expectEqualStrings("", try mem.concat(&ctx, "", ""));
}

test "mem: allocArray / cloneArrayBytes" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 1024,
        .immortal_capacity = 64,
    });
    defer ctx.deinit();

    const backing = try mem.allocArray(&ctx, 4, 8, 8); // 4 × i64
    try testing.expectEqual(@as(usize, 32), backing.len);

    const src = [_]u8{ 1, 2, 3, 4, 5 };
    const cloned = try mem.cloneArrayBytes(&ctx, &src);
    try testing.expectEqualSlices(u8, &src, cloned);
}

// --- err --------------------------------------------------------------------

test "err: construction and code-only equality" {
    const a = err.makeCode("Boom");
    const b = err.make("Boom", .{ .int = 42 });
    const c = err.make("Other", .{ .int = 42 });
    // VM valuesEqual compares codes only — payloads are ignored.
    try testing.expect(err.eq(a, b));
    try testing.expect(!err.eq(a, c));
    try testing.expect(err.isError(a));
    try testing.expectEqualStrings("Boom", b.code);
    try testing.expectEqual(@as(i64, 42), b.payload.int);
}

// --- print ------------------------------------------------------------------

fn expectFmt(expected: []const u8, v: anytype) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try print.writeValue(&buf, testing.allocator, v);
    try testing.expectEqualStrings(expected, buf.items);
}

test "print: scalars" {
    try expectFmt("null", @as(?i64, null));
    try expectFmt("7", @as(?i64, 7));
    try expectFmt("true", true);
    try expectFmt("false", false);
    try expectFmt("42", @as(i64, 42));
    try expectFmt("-1", @as(i64, -1));
    try expectFmt("200", @as(u8, 200));
    try expectFmt("255", @as(u64, 255));
}

test "print: floats use VM formatting" {
    // Exact ints within i32 print without a decimal point (VM special case).
    try expectFmt("3", @as(f64, 3.0));
    try expectFmt("-2", @as(f64, -2.0));
    // Non-exact / out-of-i32-range floats go through {d}.
    try expectFmt("3.5", @as(f64, 3.5));
    try expectFmt("3.14", @as(f64, 3.14));
    try expectFmt("100000000000000000000", @as(f64, 1e20));
    // f32: direct {d}, no special case.
    try expectFmt("3", @as(f32, 3.0));
    try expectFmt("2.5", @as(f32, 2.5));
}

test "print: strings raw, byte buffers printable-checked" {
    try expectFmt("ab", "ab");
    try expectFmt("", "");
    // Printable byte span prints raw...
    var printable = [_]u8{ 'h', 'i', '\n', '\t' };
    try expectFmt("hi\n\t", @as([]u8, &printable));
    // ...non-printable falls back to the decimal list.
    var binary = [_]u8{ 1, 2, 3 };
    try expectFmt("[1, 2, 3]", @as([]u8, &binary));
    // Empty byte buffer prints nothing (VM writePackedBytes parity).
    const empty: []u8 = &.{};
    try expectFmt("", empty);
}

test "print: arrays" {
    try expectFmt("[]", [0]i64{});
    var chars = [_]u8{ 'a', 'b', 'c' };
    try expectFmt("abc", &chars); // printable int array → string
    var nums = [_]i64{ 1, 2, 3 };
    try expectFmt("[1, 2, 3]", &nums); // non-printable values
    var mixed = [_]i64{ 97, 200, 98 }; // 200 out of range → list form
    try expectFmt("[97, 200, 98]", &mixed);
    var nested = [_][2]i64{ .{ 1, 2 }, .{ 3, 4 } };
    try expectFmt("[[1, 2], [3, 4]]", &nested);
}

test "print: error values" {
    try expectFmt("Error: Boom", err.makeCode("Boom"));
    try expectFmt("Error: E — 42", err.make("E", .{ .int = 42 }));
    try expectFmt("Error: E — why", err.make("E", .{ .str = "why" }));
    try expectFmt("Error: E — true", err.make("E", .{ .boolean = true }));
    try expectFmt("Error: E — <map>", err.make("E", .{
        .agg = .{ .ptr = undefined, .kind = .map },
    }));
}

test "print: print() joins args with spaces and appends a newline" {
    var ctx = try Context.init(.{
        .allocator = testing.allocator,
        .frame_capacity = 256,
        .immortal_capacity = 256,
    });
    defer ctx.deinit();

    var cap: CaptureGuard = .{ .stdout = true };
    defer cap.deinit();
    cap.init();

    try print.print(&ctx, .{ "smoke", @as(i64, 1), true, @as(?i64, null) });
    try testing.expectEqualStrings("smoke 1 true null\n", cap.buf.items);
}

// --- widths re-export -------------------------------------------------------

test "widths: table integrity after the runtime move" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(rt.Width.i8));
    try testing.expectEqual(@as(u8, 13), @intFromEnum(rt.Width.fsize));
    try testing.expectEqualStrings("i64", rt.Width.i64.name());
    try testing.expectEqualStrings("u1", rt.widths.fromName("bool").?.name());
    try testing.expectEqualStrings("i64", rt.widths.fromName("number").?.name());
    try testing.expect(rt.widths.i64Fits(.u8, 255));
    try testing.expect(!rt.widths.i64Fits(.u8, 256));
    try testing.expect(rt.widths.i128Fits(.i8, 127));
    try testing.expect(!rt.widths.i128Fits(.i8, 128));
    try testing.expect(rt.widths.isWidening(.i32, .i64));
    try testing.expect(!rt.widths.isWidening(.i64, .i32));
    try testing.expect(rt.widths.isNarrowing(.i64, .i32));
}

// --- ShadowStack -----------------------------------------------------------

test "trace: push / pop / setLoc track the innermost frame" {
    var stack: trace.ShadowStack = .{};
    try stack.push("add", "functions.lls");
    stack.setLoc(3, 12);
    try testing.expectEqual(@as(usize, 1), stack.count);
    try testing.expectEqualStrings("add", stack.frames[0].func_name);
    try testing.expectEqual(@as(u32, 3), stack.frames[0].line);
    try testing.expectEqual(@as(u32, 12), stack.frames[0].column);

    try stack.push("main", "functions.lls");
    stack.setLoc(7, 4);
    try testing.expectEqual(@as(usize, 2), stack.count);
    // setLoc only moves the innermost frame.
    try testing.expectEqual(@as(u32, 3), stack.frames[0].line);

    stack.pop();
    try testing.expectEqual(@as(usize, 1), stack.count);
    stack.pop();
    stack.pop(); // empty pop is a no-op
    try testing.expectEqual(@as(usize, 0), stack.count);
}

test "trace: push caps at MAX_FRAMES" {
    var stack: trace.ShadowStack = .{};
    var i: usize = 0;
    while (i < trace.MAX_FRAMES) : (i += 1) try stack.push("f", "f.lls");
    try testing.expectError(error.StackOverflow, stack.push("g", "g.lls"));
    try testing.expectEqual(trace.MAX_FRAMES, stack.count);
}

// --- Frame formatting (VM `formatVmStackTrace` parity) --------------------

test "trace: frames format like the VM stack trace" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(
        "    at mul (functions.lls:5:8)\n",
        trace.formatFrame(&buf, .{ .func_name = "mul", .file = "functions.lls", .line = 5, .column = 8 }),
    );
    // Unknown location (release builds strip line ops, like OP_LINE).
    try testing.expectEqualStrings(
        "    at main (app.lls:?:?)\n",
        trace.formatFrame(&buf, .{ .func_name = "main", .file = "app.lls" }),
    );
    // Empty file mirrors the VM's `<anonymous>` fallback.
    try testing.expectEqualStrings(
        "    at f (<anonymous>:?:?)\n",
        trace.formatFrame(&buf, .{ .func_name = "f" }),
    );
}

/// Redirect stdout/stderr into a buffer for the lifetime of a test.
const CaptureGuard = struct {
    buf: std.ArrayList(u8) = .empty,
    active: bool = false,
    stdout: bool = false,

    fn init(self: *CaptureGuard) void {
        const cap: io.Capture = .{ .alloc = testing.allocator, .buf = &self.buf };
        if (self.stdout) {
            io.stdout_capture = cap;
        } else {
            io.stderr_capture = cap;
        }
        self.active = true;
    }

    fn deinit(self: *CaptureGuard) void {
        if (self.active) {
            if (self.stdout) {
                io.stdout_capture = null;
            } else {
                io.stderr_capture = null;
            }
        }
        self.buf.deinit(testing.allocator);
    }
};

// --- Context integration ---------------------------------------------------

test "context: enterFunction / leaveFunction mirror LLTS calls" {
    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 64 });
    defer ctx.deinit();
    ctx.activate();
    try testing.expect(trace.active == &ctx.trace_stack);

    const outer = try ctx.enterFunction("add", "functions.lls");
    ctx.setLine(3, 12);
    try testing.expectEqual(@as(usize, 1), ctx.trace_stack.count);

    const inner = try ctx.enterFunction("mul", "functions.lls");
    ctx.setLine(5, 8);
    try testing.expectEqual(@as(usize, 2), ctx.trace_stack.count);
    try testing.expectEqualStrings("mul", ctx.trace_stack.frames[1].func_name);

    ctx.leaveFunction(inner);
    try testing.expectEqual(@as(usize, 1), ctx.trace_stack.count);
    ctx.leaveFunction(outer);
    try testing.expectEqual(@as(usize, 0), ctx.trace_stack.count);
}

test "context: enterFunction carries the heap watermark" {
    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 64 });
    defer ctx.deinit();

    _ = try ctx.allocFrame(8, 1);
    const mark = try ctx.enterFunction("f", "f.lls");
    _ = try ctx.allocFrame(16, 1);
    try testing.expectEqual(@as(usize, 24), ctx.frame_len);
    ctx.leaveFunction(mark);
    // Frame exit rewinds to the watermark taken on entry.
    try testing.expectEqual(@as(usize, 8), ctx.frame_len);
    try testing.expectEqual(@as(usize, 0), ctx.trace_stack.count);
}

test "context: deinit clears the active shadow stack" {
    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 0 });
    ctx.activate();
    try testing.expect(trace.active == &ctx.trace_stack);
    ctx.deinit();
    try testing.expect(trace.active == null);
}

test "context: enterFunction traps at the frame cap" {
    io.silence_stderr = true;
    defer io.silence_stderr = false;

    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 0 });
    defer ctx.deinit();
    ctx.activate();

    var i: usize = 0;
    while (i < trace.MAX_FRAMES) : (i += 1) _ = try ctx.enterFunction("f", "f.lls");

    try testing.expectError(error.RuntimeError, ctx.enterFunction("g", "g.lls"));
    // The failed push leaves the depth unchanged.
    try testing.expectEqual(trace.MAX_FRAMES, ctx.trace_stack.count);
}

// --- Trap path -------------------------------------------------------------

test "io: fail prints the message, then innermost-first frames" {
    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 0 });
    defer ctx.deinit();
    ctx.activate();

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    const outer = try ctx.enterFunction("add", "functions.lls");
    ctx.setLine(3, 12);
    const inner = try ctx.enterFunction("mul", "functions.lls");
    ctx.setLine(5, 8);

    try testing.expect(io.fail("boom {d}", .{@as(u32, 1)}) == error.RuntimeError);
    try testing.expectEqualStrings(
        "Error: boom 1\n" ++
            "    at mul (functions.lls:5:8)\n" ++
            "    at add (functions.lls:3:12)\n",
        cap.buf.items,
    );

    ctx.leaveFunction(inner);
    ctx.leaveFunction(outer);
}

test "io: failMsg prints the trace too" {
    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 0 });
    defer ctx.deinit();
    ctx.activate();

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    _ = try ctx.enterFunction("main", "app.lls");
    try testing.expect(io.failMsg("nope") == error.RuntimeError);
    try testing.expectEqualStrings(
        "Error: nope\n    at main (app.lls:?:?)\n",
        cap.buf.items,
    );
}

test "io: trap without an active context prints only the message" {
    const saved = trace.active;
    trace.active = null;
    defer trace.active = saved;

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    try testing.expect(io.failMsg("solo") == error.RuntimeError);
    try testing.expectEqualStrings("Error: solo\n", cap.buf.items);
}

test "io: silence_stderr suppresses trap output" {
    io.silence_stderr = true;
    defer io.silence_stderr = false;

    var ctx = try Context.init(.{ .allocator = testing.allocator, .frame_capacity = 0 });
    defer ctx.deinit();
    ctx.activate();

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    _ = try ctx.enterFunction("f", "f.lls");
    try testing.expect(io.failMsg("quiet") == error.RuntimeError);
    try testing.expectEqualStrings("", cap.buf.items);
}
