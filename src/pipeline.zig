const std = @import("std");
const scanner = @import("scanner/root.zig");
const parser = @import("parser/root.zig");
const compiler = @import("compiler/root.zig");
const chunk_mod = @import("bytecode/chunk.zig");
const serialize = @import("bytecode/serialize.zig");
const vm_state = @import("vm/state.zig");
const execute = @import("vm/execute/root.zig");
const builtins = @import("vm/builtins/root.zig");
const zig_backend = @import("compiler/codegen/root.zig");
const print_fmt = @import("vm/builtins/print.zig");
const report = @import("errors/report.zig");
const diag = @import("errors/diag.zig");
const io = @import("io/root.zig");

pub const RunOptions = struct {
    debug: bool = true,
    strict: bool = false,
    comptime_max_loop_iterations: ?usize = null,
    /// Extra argv forwarded to `os.args()` as argv[1..] (argv[0] is the script path).
    script_args: []const []const u8 = &.{},
    max_memory_slots: usize = 1048576,
};

pub const EmitZigOptions = struct {
    debug: bool = true,
    /// Native emission typechecks under strict soundness **by default**
    /// (native-backend Core Principle #1: "Strict by Default"). Callers may
    /// pass `false` explicitly to opt out during the transition.
    strict: bool = true,
    comptime_max_loop_iterations: ?usize = null,
    /// @import path for the LLTS runtime, written into the emitted Zig source.
    runtime_path: []const u8 = "src/runtime/root.zig",
    /// Path to zig compiler executable (defaults to "zig", or env LLTS_ZIG_BIN).
    zig_bin: []const u8 = "zig",
    /// Target triple for native compilation (e.g. x86_64-linux, aarch64-macos).
    target: ?[]const u8 = null,
    /// Optimization mode passed to `zig build-exe` (e.g. "ReleaseFast", "ReleaseSmall", "Debug").
    zig_optimize: ?[]const u8 = null,
    /// What output format to emit.
    emit_mode: EmitMode = .bin,
    /// Additional arguments/options forwarded directly to `zig build-exe`.
    zig_args: []const []const u8 = &.{},

    pub const EmitMode = enum {
        bin,
        asm_code,
        llvm_ir,
        llvm_bc,
        c_header,
        docs,
        implib,
        zig_source,
    };
};

pub fn compileSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !chunk_mod.Chunk {
    var scan_result = try scanner.scan(allocator, source, path);
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source, null);
    defer doc.deinit();

    return try compiler.compile(allocator, &doc, .{
        .debug = options.debug,
        .strict = options.strict,
        .comptime_max_loop_iterations = options.comptime_max_loop_iterations,
    });
}

pub fn runChunk(
    allocator: std.mem.Allocator,
    chunk: *chunk_mod.Chunk,
    script_path: []const u8,
    script_args: []const []const u8,
    max_memory_slots: usize,
) !void {
    var state = try vm_state.VMState.init(allocator, chunk, max_memory_slots);
    defer state.deinit();
    state.script_path = script_path;
    state.script_args = script_args;
    try builtins.registerBuiltins(&state, chunk);
    execute.execute(&state, 0) catch |err| {
        if (err == error.TypeError) {
            const f = if (state.frame_count > 0) state.frame() else null;
            if (f) |frame| {
                std.debug.print("runtime TypeError in {s} ({s}:{d}:{d})\n", .{
                    frame.func_name,
                    if (frame.file.len > 0) frame.file else script_path,
                    frame.line,
                    frame.column,
                });
            } else {
                std.debug.print("runtime TypeError before first frame\n", .{});
            }
        }
        return err;
    };

    if (state.sp > 0 and state.isErrorValue(state.stack_buf[0])) {
        const err_val = state.stack_buf[0];
        const p: i32 = switch (err_val) {
            .ptr => |x| x,
            .i64 => |x| @intCast(x),
            else => unreachable,
        };
        var msg_buf: std.ArrayList(u8) = .empty;
        defer msg_buf.deinit(state.allocator);
        try print_fmt.writeValue(&state, &msg_buf, state.slot(p).*);

        const file = if (state.current_source_index < state.chunk.sources.items.len)
            state.chunk.sources.items[state.current_source_index].path
        else if (state.chunk.file.len > 0)
            state.chunk.file
        else
            script_path;
        const source = state.sourceForFile(file);
        if (state.current_line > 0 and source.len > 0) {
            report.reportSourceErrorWithFrame(file, source, state.current_line, state.current_column, msg_buf.items, "main");
        } else {
            report.reportRuntimeError(msg_buf.items);
            report.reportLocationFrameCol(file, 1, 1, "main");
        }
        return error.RuntimeError;
    }
}

pub fn runSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: RunOptions,
) !void {
    var chunk = try compileSource(allocator, path, source, options);
    defer chunk.deinit();
    try runChunk(allocator, &chunk, path, options.script_args, options.max_memory_slots);
}

pub fn writeBytecodeFile(allocator: std.mem.Allocator, chunk: *const chunk_mod.Chunk, path: []const u8) !void {
    try serialize.writeFile(allocator, chunk, path);
}

pub fn readBytecodeFile(allocator: std.mem.Allocator, path: []const u8) !chunk_mod.Chunk {
    return try serialize.readFile(allocator, path);
}

pub fn runBytecodeFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    script_args: []const []const u8,
    max_memory_slots: usize,
) !void {
    var chunk = try readBytecodeFile(allocator, path);
    defer chunk.deinit();
    try runChunk(allocator, &chunk, path, script_args, max_memory_slots);
}

/// Emit a source file as runtime-driving Zig code (the native backend output).
/// Pass any `std.io` writer; the result is a monolithic `.zig` compilation unit.
pub fn emitZigCode(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    writer: anytype,
    options: EmitZigOptions,
) !void {
    var scan_result = try scanner.scan(allocator, source, path);
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, path, source, null);
    defer doc.deinit();

    var state = try compiler.analyze(allocator, &doc, .{
        .debug = options.debug,
        .strict = options.strict,
        .comptime_max_loop_iterations = options.comptime_max_loop_iterations,
    });
    defer {
        state.chunk.deinit();
        compiler.state_mod.deinit(&state);
    }

    try zig_backend.emitRuntimeZig(allocator, &doc, &state, writer, .{
        .release = !options.debug,
        .runtime_path = options.runtime_path,
    });
}

/// Directory for zig's local cache when compiling a native unit.
///
/// The project's own `.zig-cache` holds every `zig build` artifact and grows
/// into gigabytes; measured on this repo, a cache miss there costs roughly
/// three times a miss in a small dedicated cache. Native runs are almost
/// always misses (each program's text is different, so zig re-analyzes the
/// runtime every time), which makes that gap the dominant per-run cost.
/// Keeping the two caches apart stops native builds from feeding the project
/// cache. The default lives on the system temp filesystem (`TMPDIR`, else
/// `/tmp`), which measured ~1.5x faster than a cache under `$HOME` for the same
/// work; `LLTS_NATIVE_CACHE_DIR` relocates it, and `XDG_CACHE_HOME`/`HOME` pick
/// a persistent location when no temp directory exists.
fn resolveNativeCacheDir(allocator: std.mem.Allocator) !?[]u8 {
    const dir = blk: {
        if (try nonEmptyEnv(allocator, "LLTS_NATIVE_CACHE_DIR")) |dir| break :blk dir;
        if (try nonEmptyEnv(allocator, "TMPDIR")) |base| {
            defer allocator.free(base);
            break :blk try std.fs.path.join(allocator, &.{ base, "llts-native-cache" });
        }
        if (std.fs.accessAbsolute("/tmp", .{})) |_| {
            break :blk try std.fs.path.join(allocator, &.{ "/tmp", "llts-native-cache" });
        } else |_| {}
        if (try nonEmptyEnv(allocator, "XDG_CACHE_HOME")) |base| {
            defer allocator.free(base);
            break :blk try std.fs.path.join(allocator, &.{ base, "llts", "native" });
        }
        if (try nonEmptyEnv(allocator, "HOME")) |home| {
            defer allocator.free(home);
            break :blk try std.fs.path.join(allocator, &.{ home, ".cache", "llts", "native" });
        }
        return null;
    };
    errdefer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    return dir;
}

/// Read an environment variable, treating unset and empty alike (`TMPDIR=` must
/// not turn the cache path into a relative directory inside the cwd).
fn nonEmptyEnv(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const value = std.process.getEnvVarOwned(allocator, name) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

/// Whether the caller already chose a cache directory through `zig_args`.
fn zigArgsSetCacheDir(zig_args: []const []const u8) bool {
    for (zig_args) |arg| {
        if (std.mem.eql(u8, arg, "--cache-dir") or std.mem.startsWith(u8, arg, "--cache-dir=")) return true;
    }
    return false;
}

/// Compile an LLTS source file to a native binary by emitting runtime Zig and
/// invoking `zig build-exe`.
///
/// The full front half (scan → parse → strict typecheck → emit) runs here, so
/// soundness is enforced at the native entry point before LLVM is invoked.
///
/// The emitted unit is staged inside the current directory and deleted after
/// the build: zig's root module path is the directory of the root source file,
/// and the emitter resolves the runtime `@import` against the cwd, so the two
/// only overlap when the staged file lives under the cwd.
///
/// Every `emit_mode` maps one-to-one onto a `zig build-exe` `-femit-*`
/// artifact flag (bin, asm, llvm-ir, llvm-bc, h, docs, implib). `zig_source`
/// never reaches here (`build --emit-zig` handles source output without
/// invoking zig).
pub fn compileNativeBinary(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    out_binary_path: []const u8,
    options: EmitZigOptions,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try emitZigCode(allocator, path, source, out.writer(allocator), options);

    switch (options.emit_mode) {
        .bin, .asm_code, .llvm_ir, .llvm_bc, .c_header, .docs, .implib => {},
        .zig_source => {
            std.debug.print("error: native compilation cannot output Zig source; use `llts emit-zig`\n", .{});
            diag.markEmitted();
            return error.UnsupportedEmitMode;
        },
    }

    const tmp_name = try stagedNativeName(allocator);
    defer allocator.free(tmp_name);
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_name, .data = out.items });
    defer std.fs.cwd().deleteFile(tmp_name) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var out_flag_buf: [std.fs.max_path_bytes + 32]u8 = undefined;

    try args.append(allocator, options.zig_bin);
    try args.append(allocator, "build-exe");
    const native_cache_dir = if (zigArgsSetCacheDir(options.zig_args)) null else try resolveNativeCacheDir(allocator);
    defer if (native_cache_dir) |dir| allocator.free(dir);
    if (native_cache_dir) |dir| {
        try args.append(allocator, "--cache-dir");
        try args.append(allocator, dir);
    }
    if (options.target) |target| {
        try args.append(allocator, "-target");
        try args.append(allocator, target);
    }
    if (options.zig_optimize) |mode| {
        try args.append(allocator, "-O");
        try args.append(allocator, mode);
    }
    // One artifact per invocation. `-fllvm` is required where the default
    // self-hosted x86 backend has no printer (asm) and for the artifacts
    // that zig documents as requiring LLVM extensions (llvm-ir, llvm-bc).
    const Spec = struct { kind: []const u8, no_bin: bool, llvm: bool };
    const spec: Spec = switch (options.emit_mode) {
        .bin => .{ .kind = "emit-bin", .no_bin = false, .llvm = false },
        .asm_code => .{ .kind = "emit-asm", .no_bin = true, .llvm = true },
        .llvm_ir => .{ .kind = "emit-llvm-ir", .no_bin = true, .llvm = true },
        .llvm_bc => .{ .kind = "emit-llvm-bc", .no_bin = true, .llvm = true },
        .c_header => .{ .kind = "emit-h", .no_bin = true, .llvm = false },
        .docs => .{ .kind = "emit-docs", .no_bin = true, .llvm = false },
        .implib => .{ .kind = "emit-implib", .no_bin = true, .llvm = false },
        .zig_source => unreachable,
    };
    if (spec.no_bin) try args.append(allocator, "-fno-emit-bin");
    if (spec.llvm) try args.append(allocator, "-fllvm");
    try args.append(allocator, try std.fmt.bufPrint(&out_flag_buf, "-f{s}={s}", .{ spec.kind, out_binary_path }));
    try args.append(allocator, "-lc");
    for (options.zig_args) |extra| try args.append(allocator, extra);
    try args.append(allocator, tmp_name);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        std.debug.print("error: failed to run '{s}': {s} (set --zig-bin or LLTS_ZIG_BIN)\n", .{
            options.zig_bin,
            @errorName(err),
        });
        diag.markEmitted();
        return error.NativeBuildFailed;
    };
    const zig_stderr = child.stderr.?.readToEndAlloc(allocator, 8 * 1024 * 1024) catch {
        _ = child.wait() catch {};
        std.debug.print("error: failed to read zig build output\n", .{});
        diag.markEmitted();
        return error.NativeBuildFailed;
    };
    defer allocator.free(zig_stderr);
    const term = child.wait() catch |err| {
        std.debug.print("error: waiting for zig failed: {s}\n", .{@errorName(err)});
        diag.markEmitted();
        return error.NativeBuildFailed;
    };
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    try reportNativeBuildFailure(allocator, path, source, out.items, tmp_name, zig_stderr);
    diag.markEmitted();
    return error.NativeBuildFailed;
}

/// Run an LLTS source directly via `zig run` without creating a persistent binary.
pub fn runNativeBinary(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    script_args: []const []const u8,
    options: EmitZigOptions,
) !u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try emitZigCode(allocator, path, source, out.writer(allocator), options);

    const tmp_name = try stagedNativeName(allocator);
    defer allocator.free(tmp_name);
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_name, .data = out.items });
    defer std.fs.cwd().deleteFile(tmp_name) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, options.zig_bin);
    try args.append(allocator, "run");
    const native_cache_dir = if (zigArgsSetCacheDir(options.zig_args)) null else try resolveNativeCacheDir(allocator);
    defer if (native_cache_dir) |dir| allocator.free(dir);
    if (native_cache_dir) |dir| {
        try args.append(allocator, "--cache-dir");
        try args.append(allocator, dir);
    }
    if (options.target) |target| {
        try args.append(allocator, "-target");
        try args.append(allocator, target);
    }
    if (options.zig_optimize) |mode| {
        try args.append(allocator, "-O");
        try args.append(allocator, mode);
    }
    try args.append(allocator, "-lc");
    for (options.zig_args) |extra| try args.append(allocator, extra);
    try args.append(allocator, tmp_name);
    if (script_args.len > 0) {
        try args.append(allocator, "--");
        for (script_args) |arg| {
            try args.append(allocator, arg);
        }
    }

    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        std.debug.print("error: failed to run '{s}': {s} (set --zig-bin or LLTS_ZIG_BIN)\n", .{
            options.zig_bin,
            @errorName(err),
        });
        diag.markEmitted();
        return error.NativeBuildFailed;
    };

    const zig_stderr = child.stderr.?.readToEndAlloc(allocator, 8 * 1024 * 1024) catch {
        _ = child.wait() catch {};
        std.debug.print("error: failed to read zig output\n", .{});
        diag.markEmitted();
        return error.NativeBuildFailed;
    };
    defer allocator.free(zig_stderr);

    const term = child.wait() catch |err| {
        std.debug.print("error: waiting for zig failed: {s}\n", .{@errorName(err)});
        diag.markEmitted();
        return error.NativeBuildFailed;
    };

    const code: u8 = switch (term) {
        .Exited => |c| c,
        .Signal => |sig| {
            io.printStderr("Error: native program terminated by signal {d}\n", .{sig});
            return 1;
        },
        .Stopped => |sig| {
            io.printStderr("Error: native program stopped by signal {d}\n", .{sig});
            return 1;
        },
        .Unknown => |c| {
            io.printStderr("Error: native program ended with status {d}\n", .{c});
            return 1;
        },
    };

    if (code == 0) {
        if (zig_stderr.len > 0) {
            io.printStderr("{s}", .{zig_stderr});
        }
        return 0;
    }

    if (firstZigDiagnostic(zig_stderr, tmp_name) != null) {
        try reportNativeBuildFailure(allocator, path, source, out.items, tmp_name, zig_stderr);
        diag.markEmitted();
        return code;
    }

    if (zig_stderr.len > 0) {
        io.printStderr("{s}", .{zig_stderr});
    }
    return code;
}

const GeneratedSite = struct {
    line: u32,
    column: u32,
    file: []const u8,
};

const ZigDiagnostic = struct {
    line: u32,
    message: []const u8,
};

/// Path of the staged Zig unit handed to `zig`. It is written to the working
/// directory, so the name must be unique per invocation: a name shared between
/// concurrent native builds lets one compile (or find deleted) another's unit.
fn stagedNativeName(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".llts_native_{x}.zig", .{std.crypto.random.int(u64)});
}

/// Parse the first `path:line:col: error: …` line that names the staged file.
fn firstZigDiagnostic(stderr: []const u8, tmp_name: []const u8) ?ZigDiagnostic {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, tmp_name) orelse continue;
        const rest = line[at + tmp_name.len ..];
        if (rest.len == 0 or rest[0] != ':') continue;
        var parts = std.mem.splitScalar(u8, rest[1..], ':');
        const line_text = parts.next() orelse continue;
        _ = parts.next() orelse continue; // column
        const line_no = std.fmt.parseInt(u32, line_text, 10) catch continue;
        const msg_at = std.mem.indexOf(u8, line, "error: ") orelse continue;
        return .{ .line = line_no, .message = line[msg_at + "error: ".len ..] };
    }
    return null;
}

/// Find the last `// llts-site <line> <column> <file>` marker at or before
/// `zig_line` in the emitted Zig source.
fn findGeneratedSite(zig_source: []const u8, zig_line: u32) ?GeneratedSite {
    const prefix = "// llts-site ";
    var found: ?GeneratedSite = null;
    var lines = std.mem.splitScalar(u8, zig_source, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| {
        n += 1;
        if (n > zig_line) break;
        const line = std.mem.trimLeft(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const body = line[prefix.len..];
        const first = std.mem.indexOfScalar(u8, body, ' ') orelse continue;
        const second_rel = std.mem.indexOfScalar(u8, body[first + 1 ..], ' ') orelse continue;
        const second = first + 1 + second_rel;
        const line_no = std.fmt.parseInt(u32, body[0..first], 10) catch continue;
        const col_no = std.fmt.parseInt(u32, body[first + 1 .. second], 10) catch continue;
        const file = std.mem.trimRight(u8, body[second + 1 ..], " \t\r");
        if (file.len == 0) continue;
        found = .{ .line = line_no, .column = col_no, .file = file };
    }
    return found;
}

/// Check whether a Zig diagnostic message originates from an inline assembly block or constraint.
fn looksLikeAsmError(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "asm") != null or
        std.mem.indexOf(u8, message, "assembly") != null or
        std.mem.indexOf(u8, message, "Clobber") != null;
}

/// Fallback printer that sanitizes temporary generated Zig filenames from compiler stderr.
fn printWithoutStagedPath(stderr: []const u8, tmp_name: []const u8) void {
    var rest = stderr;
    while (std.mem.indexOf(u8, rest, tmp_name)) |at| {
        std.debug.print("{s}<generated>", .{rest[0..at]});
        rest = rest[at + tmp_name.len ..];
    }
    std.debug.print("{s}", .{rest});
}

/// Map a native Zig compilation failure back to the original LLTS source location.
/// Finds the nearest `// llts-site` marker in generated Zig code corresponding to the failure line,
/// formats the error with an LLTS source frame, and prevents internal `.llts_native_*.zig` paths from leaking.
fn reportNativeBuildFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    zig_source: []const u8,
    tmp_name: []const u8,
    stderr: []const u8,
) !void {
    const diagnostic = firstZigDiagnostic(stderr, tmp_name) orelse {
        printWithoutStagedPath(stderr, tmp_name);
        return;
    };
    const site = findGeneratedSite(zig_source, diagnostic.line) orelse {
        printWithoutStagedPath(stderr, tmp_name);
        return;
    };
    const asm_error = looksLikeAsmError(diagnostic.message);
    const message = if (asm_error)
        try std.fmt.allocPrint(allocator, "inline assembly failed to compile: {s}", .{diagnostic.message})
    else
        try std.fmt.allocPrint(allocator, "native code generation failed: {s}", .{diagnostic.message});
    defer allocator.free(message);

    if (std.mem.eql(u8, site.file, path)) {
        report.reportSourceErrorWithFrame(path, source, site.line, site.column, message, if (asm_error) "@asm" else "<native>");
        return;
    }
    const site_source = std.fs.cwd().readFileAlloc(allocator, site.file, 1024 * 1024) catch "";
    defer if (site_source.len > 0) allocator.free(site_source);
    report.reportSourceErrorWithFrame(site.file, site_source, site.line, site.column, message, if (asm_error) "@asm" else "<native>");
}
