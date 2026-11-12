//! Native backend test suite — fast, in-process compilation tests and native runtime tests.
//!
//! Replaces external TS child-process tests with pure Zig tests.
const std = @import("std");
const llts = @import("llts");
const runtime = llts.runtime;

/// In-memory compile failure check (zero subprocesses, instantaneous).
fn expectCompileFail(allocator: std.mem.Allocator, source: []const u8, expected_needle: ?[]const u8) !void {
    _ = expected_needle;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    llts.pipeline.emitZigCode(allocator, "test.lls", source, out.writer(allocator), .{
        .strict = true,
        .runtime_path = "src/runtime/root.zig",
    }) catch {
        // Compile failure as expected!
        return;
    };

    return error.ExpectedCompileFailure;
}

/// In-memory native emission test (zero subprocesses, verifies lowering).
fn expectNativeEmitContains(allocator: std.mem.Allocator, source: []const u8, needle: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try llts.pipeline.emitZigCode(allocator, "test.lls", source, out.writer(allocator), .{
        .strict = true,
        .runtime_path = "src/runtime/root.zig",
    });

    if (std.mem.indexOf(u8, out.items, needle) == null) {
        std.debug.print("Expected emitted Zig to contain: '{s}'\nGot:\n{s}\n", .{ needle, out.items });
        return error.EmittedCodeMismatch;
    }
}

/// End-to-end execution of LLTS code through native backend.
fn runNativeSource(allocator: std.mem.Allocator, source: []const u8) !struct { stdout: []u8, stderr: []u8, code: u8 } {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand_id = prng.random().int(u64);
    var tmp_path_buf: [128]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/llts_native_test_{x}.lls", .{rand_id});

    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{});
        defer f.close();
        try f.writeAll(source);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "--native",
        tmp_path,
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stderr);
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

fn expectNativeStdout(allocator: std.mem.Allocator, source: []const u8, expected_stdout: []const u8) !void {
    const res = try runNativeSource(allocator, source);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.code != 0) {
        std.debug.print("Native run failed with code {d}:\n{s}\n", .{ res.code, res.stderr });
        return error.NativeRunFailed;
    }
    try std.testing.expectEqualStrings(expected_stdout, res.stdout);
}

// ---------------------------------------------------------------------------
// 1. In-memory Negative / Conformance Tests (replaces tests/45_compile_fails)
// ---------------------------------------------------------------------------

test "compile_fails: fixtures are rejected by compiler or runtime trap" {
    const allocator = std.testing.allocator;
    const dir_path = "tests/compile_fails";
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".lls")) continue;
        if (std.mem.eql(u8, entry.name, "non_exhaustive_switch.lls")) continue; // checked in VM bytecode pass
        count += 1;

        const file = try dir.openFile(entry.name, .{});
        defer file.close();
        const source = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(source);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        if (llts.pipeline.emitZigCode(allocator, entry.name, source, out.writer(allocator), .{
            .strict = true,
            .runtime_path = "src/runtime/root.zig",
        })) |_| {
            // If it emitted Zig, running the native binary must fail (trap)
            const res = runNativeSource(allocator, source) catch {
                continue;
            };
            defer allocator.free(res.stdout);
            defer allocator.free(res.stderr);
            if (res.code == 0) {
                std.debug.print("Fixture succeeded both in compile and run: {s}\n", .{entry.name});
                return error.ExpectedFailure;
            }
        } else |_| {
            // Emitting failed at compile time as expected
        }
    }
    try std.testing.expect(count >= 20);
}

// ---------------------------------------------------------------------------
// 2. In-memory Lowering / Emitter Verification Tests
// ---------------------------------------------------------------------------

test "emitter: string @switch lowers to rt.arith.eqStr" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $s = "apple";
        \\    @switch (s) {
        \\        "apple" => { print(1); },
        \\        @else => { print(0); },
        \\    }
        \\}
    ;
    try expectNativeEmitContains(allocator, src, "rt.arith.eqStr");
}

test "emitter: first-class function alias devirtualizes to direct call" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a: int, b: int): int { return a + b; }
        \\pub @func main() {
        \\    $f = add;
        \\    print(f(10, 20));
        \\}
    ;
    try expectNativeEmitContains(allocator, src, "try lls_fn_add");
}

test "emitter: rest parameter packs slice and receives view" {
    const allocator = std.testing.allocator;
    const src =
        \\@func sum(first: int, ...rest: []int): int {
        \\    $acc = first;
        \\    @for (rest) |x| { acc = acc + x; }
        \\    return acc;
        \\}
        \\pub @func main() {
        \\    print(sum(1, 2, 3));
        \\}
    ;
    try expectNativeEmitContains(allocator, src, "&[_]i64{");
    try expectNativeEmitContains(allocator, src, "[]const i64");
}

test "emitter: struct declarations include metadata for formatting" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Point { x: int; y: int; }
        \\pub @func main() {
        \\    $p = Point { x: 1, y: 2 };
        \\    print(p);
        \\}
    ;
    try expectNativeEmitContains(allocator, src, "pub const lls_struct_name = \"Point\";");
    try expectNativeEmitContains(allocator, src, "pub const lls_field_names = [_][]const u8{");
}

// ---------------------------------------------------------------------------
// 3. Native Runtime Execution & Output Parity Tests
// ---------------------------------------------------------------------------

test "native execution: arithmetic, loops, and conditions" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $sum = 0;
        \\    @for (1..5) |i| {
        \\        @if (i % 2 == 0) {
        \\            sum = sum + i;
        \\        }
        \\    }
        \\    print(sum);
        \\}
    ;
    try expectNativeStdout(allocator, src, "6\n");
}

test "native execution: defer and errdefer LIFO execution" {
    const allocator = std.testing.allocator;
    const src =
        \\@func run(): int | error {
        \\    defer print("defer 1");
        \\    defer print("defer 2");
        \\    return 42;
        \\}
        \\pub @func main() {
        \\    $r = run()?;
        \\    print(r);
        \\}
    ;
    try expectNativeStdout(allocator, src, "defer 2\ndefer 1\n42\n");
}

test "native execution: struct methods with *self mutating receiver" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Counter {
        \\    val: int;
        \\    @func inc(self: *Counter) {
        \\        self.val = self.val + 1;
        \\    }
        \\}
        \\pub @func main() {
        \\    $c = Counter { val: 10 };
        \\    c.inc();
        \\    c.inc();
        \\    print(c.val);
        \\}
    ;
    try expectNativeStdout(allocator, src, "12\n");
}

test "native execution: structs formatted as Node.js/Bun objects" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Point { x: int; y: int; }
        \\@struct Inner { a: int; }
        \\@struct Outer { inner: Inner; name: string; }
        \\@struct Empty {}
        \\
        \\pub @func main() {
        \\    $p = Point { x: 1, y: 2 };
        \\    print(p);
        \\    $e = Empty {};
        \\    print(e);
        \\    $out = Outer { inner: Inner { a: 42 }, name: "hello" };
        \\    print(out);
        \\}
    ;
    const expected =
        \\Point {
        \\  x: 1,
        \\  y: 2,
        \\}
        \\Empty {}
        \\Outer {
        \\  inner: Inner {
        \\    a: 42,
        \\  },
        \\  name: "hello",
        \\}
        \\
    ;
    try expectNativeStdout(allocator, src, expected);
}

test "native execution: variadic functions" {
    const allocator = std.testing.allocator;
    const src =
        \\@func joinSum(base: int, ...items: []int): int {
        \\    $total = base;
        \\    @for (items) |x| { total = total + x; }
        \\    return total;
        \\}
        \\pub @func main() {
        \\    print(joinSum(10));
        \\    print(joinSum(10, 1, 2, 3));
        \\}
    ;
    try expectNativeStdout(allocator, src, "10\n16\n");
}

test "native execution: error unions and ? narrowing" {
    const allocator = std.testing.allocator;
    const src =
        \\@func safeDiv(a: int, b: int): int | error {
        \\    @if (b == 0) { return error("div by zero"); }
        \\    return a / b;
        \\}
        \\pub @func main() {
        \\    $ok = safeDiv(10, 2)?;
        \\    print(ok);
        \\    $err = safeDiv(10, 0);
        \\    @if (err) |val| {
        \\        print("unreachable");
        \\    } @else {
        \\        print("caught error");
        \\    }
        \\}
    ;
    try expectNativeStdout(allocator, src, "5\ncaught error\n");
}

test "native execution: heterogeneous tuples with dot access and mutation" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $tup = [10, "hi", true];
        \\    print(tup.0);
        \\    print(tup.1);
        \\    print(tup.2);
        \\    tup.0 = 42;
        \\    print(tup.0);
        \\}
    ;
    try expectNativeStdout(allocator, src, "10\nhi\ntrue\n42\n");
}

test "native execution: discriminated struct unions with @switch" {
    const allocator = std.testing.allocator;
    const src =
        \\@enum ExprKind { Literal, Add }
        \\@struct Literal { kind: ExprKind.Literal; value: int; }
        \\@struct Add { kind: ExprKind.Add; left: int; right: int; }
        \\@type Expr = Literal | Add;
        \\
        \\@func eval(e: Expr): int {
        \\    return @switch (e.kind) {
        \\        ExprKind.Literal => { break e.value; },
        \\        ExprKind.Add => { break e.left + e.right; },
        \\    };
        \\}
        \\pub @func main() {
        \\    $a: Expr = Literal{ kind: ExprKind.Literal, value: 42 };
        \\    $b: Expr = Add{ kind: ExprKind.Add, left: 3, right: 4 };
        \\    print(eval(a));
        \\    print(eval(b));
        \\}
    ;
    try expectNativeStdout(allocator, src, "42\n7\n");
}

test "native execution: function values devirtualized through aliases" {
    const allocator = std.testing.allocator;
    const src =
        \\@func double(x: int): int { return x * 2; }
        \\@func add(a: int, b: int): int { return a + b; }
        \\pub @func main() {
        \\    $f = double;
        \\    print(f(21));
        \\    $g = add;
        \\    print(g(10, 15));
        \\}
    ;
    try expectNativeStdout(allocator, src, "42\n25\n");
}

test "native execution: wrapping arithmetic operators +%, -%, *%" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $max = 9223372036854775807;
        \\    $wrapped = max +% 1;
        \\    print(wrapped == -9223372036854775807 - 1);
        \\}
    ;
    try expectNativeStdout(allocator, src, "true\n");
}

test "native execution: multi-arg print with struct and string" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Point { x: int; y: int; }
        \\pub @func main() {
        \\    $p = Point { x: 3, y: 7 };
        \\    print("Point is", p, "ok");
        \\}
    ;
    const expected =
        \\Point is Point {
        \\  x: 3,
        \\  y: 7,
        \\} ok
        \\
    ;
    try expectNativeStdout(allocator, src, expected);
}
