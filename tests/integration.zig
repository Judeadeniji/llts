const std = @import("std");

fn runLlts(allocator: std.mem.Allocator, source: []const u8) !struct { stdout: []u8, stderr: []u8, code: u8 } {
    const tmp_path = "/tmp/llts_zig_test.lls";
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{});
        defer f.close();
        try f.writeAll(source);
    }

    var child = std.process.Child.init(&.{
        "zig-out/bin/llts",
        "run",
        tmp_path,
    }, allocator);
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
    const result = try runLlts(allocator, "@func main() { print(1 + 2 * 3); }\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7") != null);
}

test "function main" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a, b) {
        \\  return a + b;
        \\}
        \\@func main() {
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
        \\@func main() {
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
        \\@func main() {
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
