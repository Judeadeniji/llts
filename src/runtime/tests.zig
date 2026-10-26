//! Native runtime unit tests — shadow-stack and trap-path semantics verified
//! against the VM oracles (`src/errors/stack_trace.zig`, `src/vm/execute/call.zig`).

const std = @import("std");
const testing = std.testing;
const rt = @import("runtime");
const Context = rt.Context;
const io = rt.io;
const trace = rt.trace;

/// Redirect stderr into a buffer for the lifetime of a test.
const CaptureGuard = struct {
    buf: std.ArrayList(u8) = .empty,
    active: bool = false,

    fn init(self: *CaptureGuard) void {
        io.stderr_capture = .{ .alloc = testing.allocator, .buf = &self.buf };
        self.active = true;
    }

    fn deinit(self: *CaptureGuard) void {
        if (self.active) io.stderr_capture = null;
        self.buf.deinit(testing.allocator);
    }
};

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

// --- Context integration ---------------------------------------------------

test "context: enterFunction / leaveFunction mirror LLTS calls" {
    var ctx = Context.init(testing.allocator);
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

test "context: deinit clears the active shadow stack" {
    var ctx = Context.init(testing.allocator);
    ctx.activate();
    try testing.expect(trace.active == &ctx.trace_stack);
    ctx.deinit();
    try testing.expect(trace.active == null);
}

test "context: enterFunction traps at the frame cap" {
    io.silence_stderr = true;
    defer io.silence_stderr = false;

    var ctx = Context.init(testing.allocator);
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.activate();

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    const outer = try ctx.enterFunction("add", "functions.lls");
    ctx.setLine(3, 12);
    const inner = try ctx.enterFunction("mul", "functions.lls");
    ctx.setLine(5, 8);

    try testing.expectError(error.RuntimeError, io.fail("boom {d}", .{@as(u32, 1)}));
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.activate();

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    _ = try ctx.enterFunction("main", "app.lls");
    try testing.expectError(error.RuntimeError, io.failMsg("nope"));
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

    try testing.expectError(error.RuntimeError, io.failMsg("solo"));
    try testing.expectEqualStrings("Error: solo\n", cap.buf.items);
}

test "io: silence_stderr suppresses trap output" {
    io.silence_stderr = true;
    defer io.silence_stderr = false;

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.activate();

    var cap: CaptureGuard = .{};
    defer cap.deinit();
    cap.init();

    _ = try ctx.enterFunction("f", "f.lls");
    try testing.expectError(error.RuntimeError, io.failMsg("quiet"));
    try testing.expectEqualStrings("", cap.buf.items);
}
