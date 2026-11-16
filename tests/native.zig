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

const NativeFileResult = struct { stdout: []u8, stderr: []u8, code: u8 };

fn runNativeFile(allocator: std.mem.Allocator, path: []const u8) !NativeFileResult {
    var child = std.process.Child.init(&.{ "zig-out/bin/llts", "run", path }, allocator);
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

fn expectNativeFileFailure(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) !void {
    const res = try runNativeFile(allocator, path);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.code == 0) {
        std.debug.print("Expected native compile failure for {s}, got success:\n{s}\n", .{ path, res.stdout });
        return error.ExpectedCompileFailure;
    }
    if (std.mem.indexOf(u8, res.stderr, needle) == null) {
        std.debug.print("Expected stderr to contain '{s}', got:\n{s}\n", .{ needle, res.stderr });
        return error.UnexpectedDiagnostic;
    }
}

fn expectNativeFileStdout(allocator: std.mem.Allocator, path: []const u8, expected_stdout: []const u8) !void {
    const res = try runNativeFile(allocator, path);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.code != 0) {
        std.debug.print("Native run failed with code {d}:\n{s}\n", .{ res.code, res.stderr });
        return error.NativeRunFailed;
    }
    try std.testing.expectEqualStrings(expected_stdout, res.stdout);
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

/// The `# expect: <text>` line every fixture carries: the diagnostic the
/// compiler (or the trap, for emitted code) must produce.
fn expectedDiagnostic(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# expect:")) {
            return std.mem.trim(u8, line["# expect:".len..], " \t\r");
        }
    }
    return null;
}

test "compile_fails: fixtures are rejected with their declared diagnostic" {
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

        const expected = expectedDiagnostic(source) orelse {
            std.debug.print("Fixture has no '# expect:' line: {s}\n", .{entry.name});
            return error.MissingExpectation;
        };

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var diagnostics: std.ArrayList(u8) = .empty;
        defer diagnostics.deinit(allocator);
        llts.io.out.captureStderr(&diagnostics, allocator);
        defer llts.io.out.captureStderr(null, allocator);

        if (llts.pipeline.emitZigCode(allocator, entry.name, source, out.writer(allocator), .{
            .strict = true,
            .runtime_path = "src/runtime/root.zig",
        })) |_| {
            // If it emitted Zig, running the native binary must fail (trap)
            const res = runNativeSource(allocator, source) catch {
                if (std.mem.indexOf(u8, diagnostics.items, expected) == null) {
                    std.debug.print("Fixture '{s}' expected '{s}', got:\n{s}\n", .{ entry.name, expected, diagnostics.items });
                    return error.UnexpectedDiagnostic;
                }
                continue;
            };
            defer allocator.free(res.stdout);
            defer allocator.free(res.stderr);
            if (res.code == 0) {
                std.debug.print("Fixture succeeded both in compile and run: {s}\n", .{entry.name});
                return error.ExpectedFailure;
            }
            // The trap message comes from the child process, not the collector.
            if (std.mem.indexOf(u8, res.stderr, expected) == null and
                std.mem.indexOf(u8, diagnostics.items, expected) == null)
            {
                std.debug.print("Fixture '{s}' expected '{s}', got:\n{s}{s}\n", .{ entry.name, expected, diagnostics.items, res.stderr });
                return error.UnexpectedDiagnostic;
            }
        } else |_| {
            // Emitting failed at compile time: the collected diagnostic must
            // carry the message the fixture declares.
            if (std.mem.indexOf(u8, diagnostics.items, expected) == null) {
                std.debug.print("Fixture '{s}' expected '{s}', got:\n{s}\n", .{ entry.name, expected, diagnostics.items });
                return error.UnexpectedDiagnostic;
            }
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

test "native execution: range bounds accept expressions" {
    const allocator = std.testing.allocator;
    const src =
        \\@func twice(x: int): int { return x * 2; }
        \\pub @func main() {
        \\    $n = 2;
        \\    @for (1..n + 1) |i| {
        \\        print(i);
        \\    }
        \\    @for (n - 1..twice(n) + 1) |i| {
        \\        print(i);
        \\    }
        \\    $s = "abcdef";
        \\    print(s[n - 2..n + 1]);
        \\}
    ;
    try expectNativeStdout(allocator, src, "1\n2\n1\n2\n3\n4\nabc\n");
}

test "native execution: comptime range bounds accept expressions" {
    const allocator = std.testing.allocator;
    const src =
        \\@func factorial(n: i64): i64 {
        \\    $result = 1;
        \\    @for (1..n + 1) |i| {
        \\        result = result * i;
        \\    }
        \\    return result;
        \\}
        \\@const $FACT_5 = @comptime factorial(5);
        \\pub @func main() {
        \\    print(FACT_5);
        \\}
    ;
    try expectNativeStdout(allocator, src, "120\n");
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
    try expectNativeStdout(allocator, src, "10\nhi\n1\n42\n");
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
    try expectNativeStdout(allocator, src, "1\n");
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

test "native execution: string slicing" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $s = "hello world";
        \\    print(s[0..5]);
        \\    print(s[6..]);
        \\    print(s[..5]);
        \\}
    ;
    try expectNativeStdout(allocator, src, "hello\nworld\nhello\n");
}

test "native execution: slice views alias backing storage" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Bag { items: [3]i64; }
        \\pub @func main() {
        \\    $buffer = [1, 2, 3, 4, 5];
        \\    $view = buffer[1..4];
        \\    view[0] = 99;
        \\    print(buffer[1], view[0]);
        \\
        \\    $copy = buffer;
        \\    copy[0] = 7;
        \\    print(buffer[0], copy[0]);
        \\
        \\    $bag = Bag { items: [10, 20, 30] };
        \\    $items = bag.items[1..];
        \\    items[0] = 55;
        \\    print(bag.items[1], items[0]);
        \\}
    ;
    try expectNativeStdout(allocator, src, "99 99\n1 7\n55 55\n");
}

test "native execution: borrowed slices may be returned from caller storage" {
    const allocator = std.testing.allocator;
    const src =
        \\@func tail(a: *[3]i64): []i64 {
        \\    return a[1..];
        \\}
        \\@func id(a: []i64): []i64 {
        \\    return a;
        \\}
        \\pub @func main() {
        \\    $buffer = [1, 2, 3];
        \\    $rest = tail(&buffer);
        \\    print(rest[0], rest[1]);
        \\    $same = id(buffer[0..]);
        \\    print(same[0], same[2]);
        \\}
    ;
    try expectNativeStdout(allocator, src, "2 3\n1 3\n");
}

test "native execution: bitwise, float arithmetic, and value @if capture" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a = 5 & 3;
        \\    $b = 5 | 2;
        \\    $c = 5 ^ 1;
        \\    $d = 1 << 4;
        \\    $e = 32 >> 2;
        \\    print(a, b, c, d, e);
        \\
        \\    $f1: float = 3.5;
        \\    $f2: float = 1.5;
        \\    print(f1 + f2, f1 - f2);
        \\
        \\    $opt: ?int = 42;
        \\    @if (opt) |v| {
        \\        print("has val", v);
        \\    }
        \\    $none: ?int = null;
        \\    $val = @if (none) |v| { break v; } @else { break 99; };
        \\    print(val);
        \\}
    ;
    try expectNativeStdout(allocator, src, "1 7 5 16 8\n5 2\nhas val 42\n99\n");
}

test "emitter: extern declarations and direct C calls" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" @func puts(s: c_str): i32;
        \\@extern "c" @func printf(fmt: c_str, ...): i32;
        \\@extern "c" @func getenv(name: c_str): ?c_str;
        \\pub @func main() {
        \\    $r: i32 = puts("hello");
        \\    $v: i32 = printf("%d\n", 42);
        \\    $e: ?c_str = getenv("PATH");
        \\}
    ;
    try expectNativeEmitContains(allocator, src, "extern fn puts(s: [*:0]const u8) i32;");
    try expectNativeEmitContains(allocator, src, "extern fn printf(fmt: [*:0]const u8, ...) i32;");
    try expectNativeEmitContains(allocator, src, "extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;");
    try expectNativeEmitContains(allocator, src, "puts(\"hello\")");
    try expectNativeEmitContains(allocator, src, "printf(\"%d\\n\", @as(i32, 42))");
}

test "native execution: extern calls, C returns, and variadic promotion" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" @func printf(fmt: c_str, ...): i32;
        \\@extern "c" @func strlen(s: c_str): usize;
        \\@extern "c" @func getpid(): i32;
        \\@extern "c" @func malloc(size: usize): ?*u8;
        \\@extern "c" @func free(p: ?*u8): void;
        \\pub @func main() {
        \\    $n: usize = strlen("hello");
        \\    print(n);
        \\    $pid: i32 = getpid();
        \\    print(pid > 0);
        \\    $p: ?*u8 = malloc(8);
        \\    free(p);
        \\    printf("hello %s %d\n", "world", 42);
        \\    $f: f32 = 1.5;
        \\    printf("f=%f\n", f);
        \\    $a: i8 = @as(i8, -5);
        \\    $b: u8 = @as(u8, 7);
        \\    printf("i=%d u=%d b=%d\n", a, b, true);
        \\}
    ;
    try expectNativeStdout(allocator, src, "5\n1\nhello world 42\nf=1.500000\ni=-5 u=7 b=1\n");
}

test "native execution: extern byte buffer and optional c_str" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" @func printf(fmt: c_str, ...): i32;
        \\@extern "c" @func getenv(name: c_str): ?c_str;
        \\@extern "c" @func memset(p: *u8, c: i32, n: usize): ?*u8;
        \\pub @func main() {
        \\    $buf: [4]u8 = [0, 0, 0, 0];
        \\    _ = memset(buf, 65, 4);
        \\    printf("%c%c%c%c\n", buf[0], buf[1], buf[2], buf[3]);
        \\    $lit: c_str = "x";
        \\    printf("lit=%d\n", strlen(lit));
        \\    $env: ?c_str = getenv("PATH");
        \\    @if (env) |v| {
        \\        $zero: usize = 0;
        \\        printf("env=%d\n", strlen(v) > zero);
        \\    } @else {
        \\        print("missing");
        \\    }
        \\}
        \\@extern "c" @func strlen(s: c_str): usize;
    ;
    try expectNativeStdout(allocator, src, "AAAA\nlit=1\nenv=1\n");
}

test "native execution: imported pub extern links its bare symbol" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "tests/fixtures/extern_main.lls",
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    if (code != 0) {
        std.debug.print("Native run failed with code {d}:\n{s}\n", .{ code, stderr });
        return error.NativeRunFailed;
    }
    try std.testing.expectEqualStrings("from-module\n", stdout);
}

test "emitter: extern data symbols emit mutable extern vars" {
    const allocator = std.testing.allocator;
    const src =
        \\@extern "c" optind: i32;
        \\pub @func main() {
        \\    $a: i32 = optind;
        \\    optind = a + 1;
        \\}
    ;
    try expectNativeEmitContains(allocator, src, "extern var optind: i32;");
    try expectNativeEmitContains(allocator, src, "optind = ");
}

test "native execution: extern data reads and writes" {
    const allocator = std.testing.allocator;
    const src =
        \\@extern "c" optind: i32;
        \\pub @func main() {
        \\    print(@nameOf(optind));
        \\    print(@sizeOf(@typeOf(optind)));
        \\    optind = 123;
        \\    $x: i32 = optind;
        \\    print(x);
        \\}
    ;
    try expectNativeStdout(allocator, src, "optind\n4\n123\n");
}

test "native execution: imported extern data reads and writes" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/extern_data_main.lls", "41\n42\n");
}

test "native compile: private extern function is not a module export" {
    try expectNativeFileFailure(std.testing.allocator, "tests/fixtures/extern_private_fn_main.lls", "has no export 'getpid'");
}

test "native compile: private extern data is not a module export" {
    try expectNativeFileFailure(std.testing.allocator, "tests/fixtures/extern_private_data_main.lls", "has no export 'optind'");
}

test "native compile: private functions are not module exports" {
    try expectNativeFileFailure(std.testing.allocator, "tests/fixtures/private_fn_main.lls", "has no export 'hidden'");
}

test "native execution: public wrappers can use private functions" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/private_fn_ok_main.lls", "7\n");
}

test "native execution: public wrappers can use private externs" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/extern_private_ok_main.lls", "1\n55\n");
}

test "native execution: extern signatures accept optional struct pointers" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/extern_optional_struct_ptr_main.lls", "");
}

test "native execution: syscall file write, seek, read, unlink" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_file_main.lls", "6\n4\n108\n99\n");
}

test "native execution: syscall truncate_file shrinks an open file" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_truncate_main.lls", "3\n3\n99\n0\n");
}

test "native execution: syscall errors are values and empty reads return zero" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_errors_main.lls", "open-failed\n0\n");
}

test "native execution: never-returning exit sets the process status" {
    const allocator = std.testing.allocator;
    const res = try runNativeFile(allocator, "tests/fixtures/syscall_exit_main.lls");
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try std.testing.expectEqual(@as(u8, 2), res.code);
    try std.testing.expectEqualStrings("", res.stdout);
}

test "native execution: imported extern signatures naming module-local types" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_extern_main.lls", "7\n");
}

test "native execution: syscall io pipe, pread, pwrite, fcntl, dup, truncate" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_io_ops_main.lls", "7\n112\n4\n52\n2\n65\n0\n65\n5\n1\n");
}

test "native execution: syscall dir mkdir, access, link, rename, rmdir" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_dir_ops_main.lls", "mkdir-ok\naccess-ok\n13\nrename-ok\ncleanup-ok\n");
}

test "native execution: syscall process id, credentials, pgrp, sid, yield, sleep" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_process_ops_main.lls", "pid-ok\nppid-ok\nuid-ok\ngid-ok\npgrp-ok\nsid-ok\nyield-sleep-ok\nalarm-ok\n");
}

test "native execution: syscall process fork, wait, exit status" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_process_wait_main.lls", "wait-pid-ok\nexited-ok\n0\n");
}

test "native execution: syscall signal kill and time retrieval" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_signal_time_main.lls", "kill-ok\ntime-ok\nclock-ok\n");
}

test "native execution: syscall memory mmap, mprotect, flock, eventfd" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_mem_event_main.lls", "pagesize-ok\nmmap-ok\nmprotect-ok\nmadvise-ok\nmunmap-ok\nmemfd-flock-ok\neventfd-ok\n");
}

test "native execution: syscall term, sysconf, priority, hardware info, getrandom" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_term_sys_main.lls", "is-term-ok\nsysconf-ok\nnprocs-ok\nphys-pages-ok\nhostid-ok\nprio-ok\nsched-prio-ok\ngetrandom-ok\n");
}

test "native execution: syscall umask, getresuid, getresgid, mremap, getauxval, ftok" {
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_misc_ops_main.lls", "umask-ok\nresuid-ok\nresgid-ok\nmremap-ok\nauxval-ok\nftok-ok\n");
}

test "native execution: syscall c extern struct ABI layout, sizeOf, and alignOf" {
    const expected =
        \\16
        \\8
        \\144
        \\8
        \\8
        \\4
        \\60
        \\4
        \\16
        \\8
        \\16
        \\8
        \\16
        \\2
        \\stat-call-ok
        \\
    ;
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_extern_struct_main.lls", expected);
}

test "native execution: syscall stat, fstat, statfs, statvfs, chmod, utimensat" {
    const expected =
        \\dev-null-is-char-device
        \\root-is-directory
        \\stdin-fstat-ok
        \\statfs-dev-ok
        \\statvfs-dev-ok
        \\file-is-regular-size-9
        \\chmod-0600-ok
        \\utimensat-ok
        \\
    ;
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_stat_main.lls", expected);
}

test "native execution: syscall time, poll, rlimit, termios" {
    const expected =
        \\clock-gettime-realtime-ok
        \\clock-getres-ok
        \\poll-stdout-writable-ok
        \\rlimit-nofile-ok
        \\prlimit-cur-proc-ok
        \\term-is-terminal-and-attrs-read
        \\
    ;
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_time_poll_system_main.lls", expected);
}

test "native execution: syscall facade major type re-exports" {
    const expected =
        \\0 1 1000 1000
        \\1 0 0 64 256 0 4
        \\Error: FileNotFound
        \\16 144 120 112 8 60 16
        \\
    ;
    try expectNativeFileStdout(std.testing.allocator, "tests/fixtures/syscall_reexports_main.lls", expected);
}

test "native execution: @zeroed builds zero values" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Inner { a: i32; b: bool; }
        \\@enum Color { Red, Green, Blue }
        \\@type Pair = [i64, bool];
        \\@struct Config {
        \\    x: i64;
        \\    f: f64;
        \\    flag: bool;
        \\    inner: Inner;
        \\    arr: [3]u8;
        \\    opt: ?*Inner;
        \\    s: string;
        \\}
        \\pub @func main() {
        \\    $c: Config = @zeroed(Config);
        \\    $a: [4]i64 = @zeroed([4]i64);
        \\    $p: Pair = @zeroed(Pair);
        \\    $col: Color = @zeroed(Color);
        \\    print(c.x, c.f, c.flag, c.inner.a, c.inner.b, c.arr[2], c.opt == null);
        \\    print(a[0], a[3], p.0, p.1, c.s == "", col);
        \\}
    ;
    try expectNativeStdout(allocator, src, "0 0 0 0 0 0 1\n0 0 0 0 1 0\n");
}

test "native execution: @zeroed slices are real empty slices" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $s: string = @zeroed(string);
        \\    $b: []byte = @zeroed([]byte);
        \\    print(s == "", b == @zeroed([]byte));
        \\}
    ;
    try expectNativeStdout(allocator, src, "1 1\n");
}

test "native compile: @zeroed diagnostic names the offending part" {
    try expectNativeFileFailure(
        std.testing.allocator,
        "tests/fixtures/zeroed_non_null_ptr_main.lls",
        "part 'conn.handle' has type '*Handle', a non-null pointer",
    );
}
