const std = @import("std");
const llts = @import("llts");
const io = llts.io;
const cli = @import("cli/root.zig");

pub const std_options: std.Options = .{
    .logFn = zigLogFn,
};

fn zigLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level: io.Level = switch (message_level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const scope_name = @tagName(scope);
    io.log.log(level, scope_name, format, args);
}

pub fn main() !void {
    io.color.initFromEnv();
    io.log.initFromEnv();

    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Use a 0-byte buffer for stdout to make it unbuffered. 
    // This ensures zli's built-in exit(0) on --help prints immediately without needing a deferred flush.
    // llts dump and other heavy IO manually buffer and do single large writeAll calls, so performance is fine.
    var wbuf: [0]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&rbuf);
    const stdin = &stdin_reader.interface;

    const root = try cli.build(stdout, stdin, gpa);
    defer root.deinit();

    try root.execute(.{});
}
