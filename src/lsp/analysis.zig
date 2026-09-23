const std = @import("std");
const llts = @import("llts");

/// Everything a feature handler needs about an open document, built once per
/// document version and reused by hover, definition, and diagnostics.
/// All allocations live in `arena`; free the whole thing with `deinit`.
///
/// IMPORTANT: an `Analysis` must live at a stable address (heap-allocated)
/// before `analyzeInPlace` runs. Every child structure (parser document,
/// typecheck hash maps, token list) captures `arena.allocator()`, which embeds
/// the arena's address; copying the struct by value afterwards leaves those
/// interfaces dangling and segfaults on the next free.
pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    /// Server-owned? No — duped into `arena` at creation, so it outlives the
    /// request that triggered analysis.
    uri: []const u8,
    /// Duped into `arena` at creation.
    source: []const u8,
    version: u64,
    scan: llts.scanner.ScanResult,
    doc: llts.ast.Document,
    typecheck_state: ?*llts.compiler.state_ext.CompilerState,
    /// Set when typecheck failed: the last compiler error, for diagnostics.
    tc_diagnostic: ?CompilerDiagnostic = null,

    pub fn deinit(self: *Analysis) void {
        if (self.typecheck_state) |cs| llts.compiler.state_ext.deinit(cs);
        self.typecheck_state = null;
        self.doc.deinit();
        llts.scanner.deinitScanResult(&self.scan);
        self.arena.deinit();
    }
};

/// Create an uninitialized-but-safe `Analysis` at a stable heap address.
/// Caller owns the allocation; call `deinit` then destroy.
pub fn create(parent: std.mem.Allocator, uri: []const u8, source: []const u8) !*Analysis {
    const a = try parent.create(Analysis);
    errdefer parent.destroy(a);
    a.* = .{
        .arena = std.heap.ArenaAllocator.init(parent),
        .uri = "",
        .source = "",
        .version = 0,
        .scan = undefined,
        .doc = undefined,
        .typecheck_state = null,
    };
    errdefer a.arena.deinit();
    const alloc = a.arena.allocator();
    a.uri = try alloc.dupe(u8, uri);
    a.source = try alloc.dupe(u8, source);
    // Safe empty values so `deinit` works even if analysis fails early.
    a.scan = .{ .tokens = .empty, .allocator = alloc };
    a.doc = .{
        .path = a.uri,
        .source = a.source,
        .statements = &.{},
        .diagnostics = &.{},
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
    return a;
}

pub const AnalyzeError = error{ ScanFailed, ParseFailed, OutOfMemory };

/// A located compiler error, 1-based line/column (same convention as parser
/// `Diagnostic`). Message is duped into the analysis arena.
pub const CompilerDiagnostic = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

/// Scan + parse + typecheck into `a.arena`. Typechecking is best-effort:
/// failure leaves `typecheck_state` populated but with partial results, which
/// is still useful for hover. On error the analysis stays deinit-able.
pub fn analyzeInPlace(a: *Analysis, version: u64) AnalyzeError!void {
    const alloc = a.arena.allocator();
    a.version = version;

    a.scan = llts.scanner.scan(alloc, a.source, a.uri) catch return error.ScanFailed;

    // Parser takes ownership of the diagnostics array it is given.
    var diags: std.ArrayList(llts.ast.Diagnostic) = .empty;
    a.doc = llts.parser.parse(alloc, a.scan.tokens.items, a.uri, a.source, &diags) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ParseFailed,
        };
    };

    var cs_val: ?llts.compiler.state_ext.CompilerState = llts.compiler.state_ext.create(alloc) catch null;
    if (cs_val != null) {
        const cs = &cs_val.?;
        // Registration passes first — without them the function registry is
        // empty and typecheck silently passes calls to unknown functions.
        if (llts.compiler.prepareForTypecheck(cs, &a.doc)) |_| {
            // Best-effort: partial results are fine for editor features.
            if (llts.compiler.typecheck_ext.typecheck(cs, &a.doc)) |_| {
                a.tc_diagnostic = null;
            } else |_| {
                // Typecheck failed: surface the captured compiler error as a
                // diagnostic — but only if it points at this document (errors
                // in imported modules would land at the wrong file).
                if (cs.last_error_message.len > 0) {
                    const err_path = cs.last_error_path;
                    if (err_path.len == 0 or std.mem.eql(u8, err_path, a.uri)) {
                        a.tc_diagnostic = .{
                            .line = cs.last_error_line,
                            .column = cs.last_error_column,
                            .message = alloc.dupe(u8, cs.last_error_message) catch "",
                        };
                    }
                }
            }
        } else |_| {}
        if (alloc.create(llts.compiler.state_ext.CompilerState)) |heap_cs| {
            heap_cs.* = cs_val.?;
            a.typecheck_state = heap_cs;
        } else |_| {
            llts.compiler.state_ext.deinit(cs);
        }
    }
}
