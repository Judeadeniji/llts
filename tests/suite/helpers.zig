const std = @import("std");
const llts = @import("llts");

pub const scanner = llts.scanner;
pub const parser = llts.parser;
pub const ast = llts.ast;
pub const compiler = llts.compiler;
pub const pipeline = llts.pipeline;

/// Scan source into tokens. Caller must call `deinitScanResult(&result)`.
pub fn scanSource(allocator: std.mem.Allocator, source: []const u8) !scanner.ScanResult {
    return scanner.scan(allocator, source, "test.lls");
}

/// Parse source into an AST document. Caller must call `doc.deinit()`.
pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !ast.Document {
    var scan_res = try scanSource(allocator, source);
    defer scanner.deinitScanResult(&scan_res);
    return parser.parse(allocator, scan_res.tokens.items, "test.lls", source, null);
}

pub const Analyzed = struct {
    doc: ast.Document,
    state: compiler.state_mod.CompilerState,

    pub fn deinit(self: *Analyzed) void {
        self.state.chunk.deinit();
        compiler.state_mod.deinit(&self.state);
        self.doc.deinit();
    }
};

/// Run compiler frontend analysis (typecheck, reachability, binding facts).
/// Caller must call `analyzed.deinit()`.
pub fn analyzeSource(allocator: std.mem.Allocator, source: []const u8, strict: bool) !Analyzed {
    var doc = try parseSource(allocator, source);
    errdefer doc.deinit();

    const state = try compiler.analyze(allocator, &doc, .{
        .debug = true,
        .strict = strict,
    });
    return .{ .doc = doc, .state = state };
}

/// Verify that analyzing this source produces a compiler / typecheck error.
pub fn expectCompileFail(allocator: std.mem.Allocator, source: []const u8) !void {
    var doc = parseSource(allocator, source) catch {
        // Parsing failed — that is also a valid compile-time rejection
        return;
    };
    defer doc.deinit();

    var state = compiler.analyze(allocator, &doc, .{
        .debug = true,
        .strict = true,
    }) catch {
        // Compile/typecheck failed as expected
        return;
    };
    defer {
        state.chunk.deinit();
        compiler.state_mod.deinit(&state);
    }

    return error.ExpectedCompileFailure;
}

/// Emit Zig code from LLTS source and return the emitted string.
pub fn emitZigString(allocator: std.mem.Allocator, source: []const u8, strict: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try pipeline.emitZigCode(allocator, "test.lls", source, out.writer(allocator), .{
        .strict = strict,
        .runtime_path = "src/runtime/root.zig",
    });

    return out.toOwnedSlice(allocator);
}

/// Assert that the emitted Zig code contains the given needle.
pub fn expectEmitContains(allocator: std.mem.Allocator, source: []const u8, needle: []const u8) !void {
    const emitted = try emitZigString(allocator, source, true);
    defer allocator.free(emitted);

    if (std.mem.indexOf(u8, emitted, needle) == null) {
        std.debug.print("Expected emitted Zig to contain: '{s}'\nGot:\n{s}\n", .{ needle, emitted });
        return error.EmittedCodeMismatch;
    }
}

/// Assert that the emitted Zig code does not contain the given needle.
pub fn expectEmitOmits(allocator: std.mem.Allocator, source: []const u8, needle: []const u8) !void {
    const emitted = try emitZigString(allocator, source, true);
    defer allocator.free(emitted);

    if (std.mem.indexOf(u8, emitted, needle)) |at| {
        std.debug.print("Expected emitted Zig to omit '{s}', found at byte {d}:\n{s}\n", .{ needle, at, emitted });
        return error.EmittedCodeUnexpected;
    }
}

/// End-to-end execution of LLTS code through the native backend.
pub fn runNativeSource(allocator: std.mem.Allocator, source: []const u8) !struct { stdout: []u8, stderr: []u8, code: u8 } {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand_id = prng.random().int(u64);
    var tmp_path_buf: [128]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/llts_suite_test_{x}.lls", .{rand_id});

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

/// Assert that executing the native binary produces the expected stdout.
pub fn expectNativeStdout(allocator: std.mem.Allocator, source: []const u8, expected_stdout: []const u8) !void {
    const res = try runNativeSource(allocator, source);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.code != 0) {
        std.debug.print("Native run failed with code {d}:\n{s}\n", .{ res.code, res.stderr });
        return error.NativeRunFailed;
    }
    try std.testing.expectEqualStrings(expected_stdout, res.stdout);
}
