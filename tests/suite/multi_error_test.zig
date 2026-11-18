//! Multi-error collection tests.
//!
//! These drive the installed `llts` binary because the CLI is where the
//! diagnostics are rendered and where `--max-errors` lives. Each case writes a
//! temporary source file, captures stderr, and checks that every fault in the
//! file is reported (in sorted order) with the tsc-style summary.

const std = @import("std");

const CliResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: *CliResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Write `source` to a temp file and run `llts <argv...> <file>`.
fn runCli(allocator: std.mem.Allocator, source: []const u8, argv: []const []const u8) !CliResult {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    // Temp files belong in the project-local .tmpdir, never /tmp (see .agents/AGENTS.md).
    try std.fs.cwd().makePath(".tmpdir");
    const tmp_dir = try std.fs.cwd().realpathAlloc(allocator, ".tmpdir");
    defer allocator.free(tmp_dir);
    const name = try std.fmt.allocPrint(allocator, "llts_multi_{x}.lls", .{prng.random().int(u64)});
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ tmp_dir, name });
    defer allocator.free(path);
    {
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll(source);
    }
    defer std.fs.deleteFileAbsolute(path) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "zig-out/bin/llts");
    try args.appendSlice(allocator, argv);
    try args.append(allocator, path);

    var child = std.process.Child.init(args.items, allocator);
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

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected output to contain '{s}'. Got:\n{s}\n", .{ needle, haystack });
        return error.OutputMismatch;
    }
}

fn expectMissing(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |at| {
        std.debug.print("Expected output to omit '{s}', found at byte {d}:\n{s}\n", .{ needle, at, haystack });
        return error.OutputUnexpected;
    }
}

test "multi error: two type errors in one function are both reported in source order" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a: int = "hello";
        \\    $b: int = true;
        \\    print(a, b);
        \\}
        \\pub @func unused() {}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "error: declaration of 'a'");
    try expectContains(res.stderr, "error: declaration of 'b'");
    try expectContains(res.stderr, "Found 2 errors in the same file");
    const first = std.mem.indexOf(u8, res.stderr, "declaration of 'a'").?;
    const second = std.mem.indexOf(u8, res.stderr, "declaration of 'b'").?;
    try std.testing.expect(first < second);
}

test "multi error: two bad statements are parser errors, not a single fatal one" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a = ;
        \\    $b = ;
        \\}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Unexpected token in expression");
    try expectContains(res.stderr, "Found 2 errors in the same file");
}

test "multi error: two broken imports are both reported" {
    const allocator = std.testing.allocator;
    const src =
        \\@const $m = @import("nope/one");
        \\@const $n = @import("nope/two");
        \\pub @func main() {}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Unknown module 'nope/one'");
    try expectContains(res.stderr, "Unknown module 'nope/two'");
    try expectContains(res.stderr, "Found 2 errors in the same file");
}

test "multi error: emitter reports both unsupported functions and never invokes zig" {
    const allocator = std.testing.allocator;
    const src =
        \\@func f() { print(f); }
        \\@func g() { print(g); }
        \\pub @func main() { f(); g(); }
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Found 2 errors in the same file");
    // No zig build output, and no generic CLI failure message.
    try expectMissing(res.stderr, "Native run failed");
    try expectMissing(res.stderr, "error: the following command failed");
}

test "multi error: emit-zig writes no partial unit when compilation fails" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a: int = "hello";
        \\    $b: int = true;
        \\}
    ;
    var res = try runCli(allocator, src, &.{"emit-zig"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try std.testing.expectEqualStrings("", res.stdout);
    try expectContains(res.stderr, "Found 2 errors in the same file");
}

test "multi error: --max-errors 1 suppresses the rest with a note" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a: int = "hello";
        \\    $b: int = true;
        \\    $c: int = "again";
        \\}
    ;
    var res = try runCli(allocator, src, &.{ "run", "--max-errors", "1" });
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "declaration of 'a'");
    try expectMissing(res.stderr, "declaration of 'b'");
    try expectContains(res.stderr, "Found 1 error in the same file");
    try expectContains(res.stderr, "2 further errors suppressed (--max-errors limit).");
}

test "multi error: folded constant overflow keeps the wrapping-operator hint" {
    const allocator = std.testing.allocator;
    const src =
        \\@const $x = 9223372036854775807 + 1;
        \\pub @func main() { print(x); }
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Integer overflow in constant expression: addition exceeds 'i64'; did you mean '+%'?");
}

test "multi error: constant overflow names the declared width, not just i64" {
    const allocator = std.testing.allocator;
    const src =
        \\@const $a: u8 = 250;
        \\@const $b: u8 = a + 10;
        \\pub @func main() { print(b); }
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "does not fit 'u8'");
    try expectMissing(res.stderr, "does not fit 'i64'");
}

test "multi error: constant overflow is diagnosed for every integer width" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        ty: []const u8,
        max: []const u8,
        expected: []const u8,
    }{
        .{ .ty = "u1", .max = "1", .expected = "value 2 does not fit 'u1'" },
        .{ .ty = "u8", .max = "255", .expected = "value 256 does not fit 'u8'" },
        .{ .ty = "i8", .max = "127", .expected = "value 128 does not fit 'i8'" },
        .{ .ty = "u16", .max = "65535", .expected = "value 65536 does not fit 'u16'" },
        .{ .ty = "i16", .max = "32767", .expected = "value 32768 does not fit 'i16'" },
        .{ .ty = "u32", .max = "4294967295", .expected = "value 4294967296 does not fit 'u32'" },
        .{ .ty = "i32", .max = "2147483647", .expected = "value 2147483648 does not fit 'i32'" },
        .{ .ty = "i64", .max = "9223372036854775807", .expected = "addition exceeds 'i64'" },
    };
    for (cases) |case| {
        const src = try std.fmt.allocPrint(
            allocator,
            "@const $a: {s} = {s};\n@const $b: {s} = a + 1;\npub @func main() {{ print(b); }}\n",
            .{ case.ty, case.max, case.ty },
        );
        defer allocator.free(src);

        var res = try runCli(allocator, src, &.{"run"});
        defer res.deinit(allocator);

        try std.testing.expectEqual(@as(u8, 1), res.code);
        try expectContains(res.stderr, case.expected);
    }
}

test "multi error: --max-errors 0 is unlimited" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a: int = "hello";
        \\    $b: int = true;
        \\    $c: int = "again";
        \\}
    ;
    var res = try runCli(allocator, src, &.{ "run", "--max-errors", "0" });
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Found 3 errors in the same file");
    try expectMissing(res.stderr, "further error");
}

test "diagnostics: unknown function suggests the closest declared function" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a: int, b: int): int { return a + b; }
        \\pub @func main() { print(ad(1, 2)); }
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Unknown function 'ad'; did you mean 'add'?");
    // And not the vague codegen message the typechecker used to fall through to.
    try expectMissing(res.stderr, "cannot infer the type of this expression");
}

test "diagnostics: unknown identifier suggests a visible name at the use site" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $value: int = 1;
        \\    print(valeu);
        \\}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Unknown identifier 'valeu'; did you mean 'value'?");
    try expectMissing(res.stderr, "Cannot assign opaque type 'unknown'");
}

test "diagnostics: arity and argument errors are both reported with a declaration note" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a: int, b: int): int { return a + b; }
        \\pub @func main() { print(add("x")); }
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Function 'add' expected at least 2 arguments, got 1");
    try expectContains(res.stderr, "argument 1 of 'add'");
    try expectContains(res.stderr, "note: 'add' is declared here");
    try expectContains(res.stderr, "Found 2 errors in the same file");
}

test "diagnostics: return mismatch notes the declared return type" {
    const allocator = std.testing.allocator;
    const src =
        \\@func f(): int { return "s"; }
        \\pub @func main() { print(f()); }
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "note: function 'f' is declared to return 'i64' here");
}

test "diagnostics: struct field mismatch notes the field type and its declaration" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @struct Point { x: int; y: int; }
        \\pub @struct Line { a: Point; b: Point; }
        \\pub @func main() {
        \\    $l: Line = { a: 5, b: { x: 1, y: 2 } };
        \\    print(l);
        \\}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Field 'a' of 'Line'");
    try expectContains(res.stderr, "note: field 'a' is declared with type 'Point' here");
    try expectContains(res.stderr, "note: type 'Point' is declared here");
}

test "diagnostics: field assignment mismatch notes the field's declared type" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @struct S { n: int; }
        \\pub @func main() {
        \\    $s: S = { n: 1 };
        \\    s.n = "x";
        \\    print(s);
        \\}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "note: field 'n' is declared with type 'i64' here");
}

test "diagnostics: a note from an imported module names that file" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    // Temp files belong in the project-local .tmpdir, never /tmp (see .agents/AGENTS.md).
    try std.fs.cwd().makePath(".tmpdir");
    const tmp_dir = try std.fs.cwd().realpathAlloc(allocator, ".tmpdir");
    defer allocator.free(tmp_dir);
    const mod_name = try std.fmt.allocPrint(allocator, "llts_note_mod_{x}.lls", .{prng.random().int(u64)});
    defer allocator.free(mod_name);
    const mod_path = try std.fs.path.join(allocator, &.{ tmp_dir, mod_name });
    defer allocator.free(mod_path);
    {
        const f = try std.fs.createFileAbsolute(mod_path, .{});
        defer f.close();
        try f.writeAll("pub @struct Thing { n: int; }\n");
    }
    defer std.fs.deleteFileAbsolute(mod_path) catch {};

    const src = try std.fmt.allocPrint(
        allocator,
        "@const $m = @import(\"{s}\");\npub @func main() {{\n    $t: m.Thing = {{ n: \"x\" }};\n    print(t);\n}}\n",
        .{mod_path},
    );
    defer allocator.free(src);

    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "note: field 'n' is declared with type 'i64' here");
    try expectContains(res.stderr, "    at ");
    try expectContains(res.stderr, mod_path);
}

test "diagnostics: too many arguments are reported with a declaration note" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a: int, b: int): int {
        \\    return a + b;
        \\}
        \\pub @func main() {
        \\    print(add(1, 2, 3));
        \\}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Function 'add' expected at most 2 arguments, got 3");
    try expectContains(res.stderr, "note: 'add' is declared here");
}

test "diagnostics: too many method arguments exclude the receiver" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Counter {
        \\    val: int;
        \\    @func add(self: *Counter, by: int) {
        \\        self.val = self.val + by;
        \\    }
        \\}
        \\pub @func main() {
        \\    $c = Counter { val: 1 };
        \\    c.add(1, 2);
        \\    print(c.val);
        \\}
    ;
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), res.code);
    try expectContains(res.stderr, "Function 'Counter::add' expected at most 1 arguments, got 2");
    try expectContains(res.stderr, "note: 'Counter::add' is declared here");
}

test "diagnostics: variadic functions still accept extra arguments" {
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
    var res = try runCli(allocator, src, &.{"run"});
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), res.code);
    try expectMissing(res.stderr, "expected at most");
}
