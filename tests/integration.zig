const std = @import("std");

const RunResult = struct { stdout: []u8, stderr: []u8, code: u8 };

fn runLlts(allocator: std.mem.Allocator, source: []const u8) !RunResult {
    return runLltsWith(allocator, source, &.{});
}

/// Run LLTS source through `llts run`, with extra flags (e.g. `--vm`).
fn runLltsWith(allocator: std.mem.Allocator, source: []const u8, flags: []const []const u8) !RunResult {
    const tmp_path = "/tmp/llts_zig_test.lls";
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{});
        defer f.close();
        try f.writeAll(source);
    }

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "zig-out/bin/llts");
    try args.append(allocator, "run");
    try args.appendSlice(allocator, flags);
    try args.append(allocator, tmp_path);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

test "print arithmetic" {
    const allocator = std.testing.allocator;
    const result = try runLlts(allocator, "pub @func main() { print(1 + 2 * 3); }\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7") != null);
}

test "function main" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a: i64, b: i64) {
        \\  return a + b;
        \\}
        \\pub @func main() {
        \\  print(add(10, 32));
        \\}
        \\
    ;
    const result = try runLlts(allocator, src);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "42") != null);
}

test "compile and run bytecode file" {
    const allocator = std.testing.allocator;
    const src_path = "/tmp/llts_zig_core_src.lls";
    const llb_path = "/tmp/llts_zig_core_out.llb";
    const src =
        \\pub @func main() {
        \\  print(99);
        \\}
        \\
    ;
    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        defer f.close();
        try f.writeAll(src);
    }

    var compile_child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "build",
        "--vm",
        "-o",
        llb_path,
        src_path,
    }, allocator);
    compile_child.stdout_behavior = .Ignore;
    compile_child.stderr_behavior = .Pipe;
    try compile_child.spawn();
    const compile_stderr = try compile_child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(compile_stderr);
    const compile_term = try compile_child.wait();
    const compile_code: u8 = switch (compile_term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    try std.testing.expectEqual(@as(u8, 0), compile_code);

    var run_child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "--vm",
        llb_path,
    }, allocator);
    run_child.stdout_behavior = .Pipe;
    run_child.stderr_behavior = .Pipe;
    try run_child.spawn();
    const stdout = try run_child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try run_child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const run_term = try run_child.wait();
    const run_code: u8 = switch (run_term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    try std.testing.expectEqual(@as(u8, 0), run_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "99") != null);
}

test "range for" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\  $s = 0;
        \\  @for (0..3) |i| {
        \\    s = s + i;
        \\  }
        \\  print(s);
        \\}
        \\
    ;
    const result = try runLlts(allocator, src);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3") != null);
}

test "eval flag root" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "-e",
        "print(10 + 32)",
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
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "42") != null);
}

test "eval flag run subcommand" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "-e",
        "print(7 * 6)",
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
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "42") != null);
}

test "eval flag with args" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "--vm",
        "--strict",
        "false",
        "-e",
        "print(__args()[1])",
        "hello_from_arg",
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
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "hello_from_arg") != null);
}

test "eval flag native default" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "-e",
        "pub @func main() { print(999); }",
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
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "999") != null);
}

test "strict mode is enabled by default" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "-e",
        "@func add(a, b) { return a + b; } pub @func main() { print(add(1, 2)); }",
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();
    try std.testing.expect(term != .Exited or term.Exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "strict mode") != null);
}

test "strict false opts out of strict mode" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        "--vm",
        "--strict",
        "false",
        "-e",
        "@func add(a, b) { return a + b; } pub @func main() { print(add(1, 2)); }",
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
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "3") != null);
}

test "compiler authority: emitter contains no display-string type parser or AST re-evaluators" {
    const allocator = std.testing.allocator;
    const emitter_dir_path = "src/compiler/codegen/emitter";
    var dir = try std.fs.cwd().openDir(emitter_dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    const forbidden = [_][]const u8{
        "fn classify",
        "fn expandTypedefs",
        "fn isErrorDisplay",
        "fn childType",
        "fn parseArrayShape",
        "fn optionalPayloadDisplay",
        "fn isConstByteSequenceDisplay",
        "fn displayForExpr",
        "fn stmtTerminates",
        "range_mod",
        "prescan",
        "int_ranges",
    };

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const content = try dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
        defer allocator.free(content);

        for (forbidden) |pattern| {
            if (std.mem.indexOf(u8, content, pattern) != null) {
                std.debug.print("Found forbidden pattern '{s}' in {s}/{s}\n", .{ pattern, emitter_dir_path, entry.name });
                try std.testing.expect(false);
            }
        }
    }
}

test "compiler authority: generated code is deterministic across multiple emits" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/llts_authority_test.lls";
    const src =
        \\@const $MAX = 100;
        \\@func helper(x: int): int {
        \\    @if (x < 2) return x;
        \\    return x * 2;
        \\}
        \\pub @func main() {
        \\    var total: int = 0;
        \\    @for (0..10) |i| {
        \\        total = total + helper(i);
        \\    }
        \\    print(total);
        \\}
        \\
    ;
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{});
        defer f.close();
        try f.writeAll(src);
    }

    // Run 1
    var child1 = std.process.Child.init(&.{ "zig-out/bin/llts", "emit-zig", tmp_path }, allocator);
    child1.stdout_behavior = .Pipe;
    child1.stderr_behavior = .Pipe;
    try child1.spawn();
    const stdout1 = try child1.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout1);
    const stderr1 = try child1.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr1);
    _ = try child1.wait();

    // Run 2
    var child2 = std.process.Child.init(&.{ "zig-out/bin/llts", "emit-zig", tmp_path }, allocator);
    child2.stdout_behavior = .Pipe;
    child2.stderr_behavior = .Pipe;
    try child2.spawn();
    const stdout2 = try child2.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout2);
    const stderr2 = try child2.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr2);
    _ = try child2.wait();

    try std.testing.expectEqualStrings(stdout1, stdout2);
}

test "layout contract: VM and native agree on ordinary aggregate sizes" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct One { a: u8; }
        \\@struct Tiny { a: u8; b: u8; }
        \\@struct Wide { a: u32; b: u32; c: u32; }
        \\@struct Mixed { a: u8; b: i64; c: u8; }
        \\pub @func main() {
        \\    print(@sizeOf(One), @alignOf(One));
        \\    print(@sizeOf(Tiny), @alignOf(Tiny));
        \\    print(@sizeOf(Wide), @alignOf(Wide));
        \\    print(@sizeOf(Mixed), @alignOf(Mixed));
        \\    print(@sizeOf([100]Tiny), @alignOf([100]Tiny));
        \\    print(@sizeOf(string), @alignOf(string));
        \\}
    ;
    const native = try runLlts(allocator, src);
    defer allocator.free(native.stdout);
    defer allocator.free(native.stderr);
    try std.testing.expectEqual(@as(u8, 0), native.code);

    const vm = try runLltsWith(allocator, src, &.{"--vm"});
    defer allocator.free(vm.stdout);
    defer allocator.free(vm.stderr);
    try std.testing.expectEqual(@as(u8, 0), vm.code);

    const expected = "1 1\n2 1\n12 4\n24 8\n200 1\n8 8\n";
    try std.testing.expectEqualStrings(expected, native.stdout);
    try std.testing.expectEqualStrings(expected, vm.stdout);
}
