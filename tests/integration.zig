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
        "-i",
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
    const result = try runLlts(allocator, "print(1 + 2 * 3)\n");
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
