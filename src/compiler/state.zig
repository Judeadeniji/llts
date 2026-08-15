const std = @import("std");
const chunk_mod = @import("../bytecode/chunk.zig");
const ast = @import("../ast/root.zig");

pub const Local = struct {
    name: []const u8,
    depth: i32,
    type_name: ?[]const u8 = null,
    is_const: bool = false,
    /// Where heap data bound to this local came from (escape analysis).
    /// `.frame` = bare struct/array literal — must not be returned.
    /// `.pass` = `@new(allocator, …)` — may escape the frame.
    alloc_region: AllocRegion = .unknown,
};

/// Heap lifetime color for escape checking (region model, not GC).
pub const AllocRegion = enum {
    unknown,
    frame,
    pass,
};

pub const FunctionDef = struct {
    node: *ast.Node,
    address: ?u32 = null,
    has_loop: bool = false,
    has_return: bool = false,
    calls: std.StringHashMap(void),
    return_type: ?[]const u8 = null,
    is_recursive: bool = false,
    forward_jumps: std.ArrayList(usize) = .empty,
    source_index: u16 = 0,
};

pub const StructDef = struct {
    name: []const u8,
    size: i32,
    offsets: std.StringHashMap(i32),
    types: std.StringHashMap([]const u8),
};

pub const EnumDef = struct {
    name: []const u8,
    variants: std.StringHashMap(i32),
};

pub const LoopTracker = struct {
    start: usize = 0,
    scope_depth: i32,
    label: ?[]const u8 = null,
    break_jumps: std.ArrayList(usize) = .empty,
    continue_jumps: std.ArrayList(usize) = .empty,
};

/// Value-producing `@if` / `@switch` / labeled block — `break <value>` targets these.
pub const ExprTracker = struct {
    scope_depth: i32,
    result_slot: u8,
    label: ?[]const u8 = null,
    break_jumps: std.ArrayList(usize) = .empty,
};

pub const DeferEntry = struct {
    body: *ast.Node,
    is_errdefer: bool,
};

pub const ImportFrame = struct {
    /// File that contains the `@import`.
    path: []const u8,
    line: u32,
    column: u32,
    /// Path string passed to `@import(...)`.
    import_path: []const u8,
};

pub const CompilerState = struct {
    allocator: std.mem.Allocator,
    chunk: chunk_mod.Chunk,
    debug: bool = true,
    locals: std.ArrayList(Local) = .empty,
    scope_depth: i32 = 0,
    functions: std.StringHashMap(FunctionDef),
    structs: std.StringHashMap(StructDef),
    enums: std.StringHashMap(EnumDef),
    loops: std.ArrayList(LoopTracker) = .empty,
    exprs: std.ArrayList(ExprTracker) = .empty,
    defer_stacks: std.AutoHashMap(i32, std.ArrayListUnmanaged(DeferEntry)),
    global_vars: std.StringHashMap(void),
    global_types: std.StringHashMap([]const u8),
    global_consts: std.StringHashMap(void),
    ready_global_consts: std.StringHashMap(void),
    native_globals: std.StringHashMap(void),
    /// Name → global slot for OP_GET/SET_GLOBAL emit.
    global_slots: std.StringHashMap(u16),
    inline_return_jumps: std.ArrayList(std.ArrayList(usize)) = .empty,
    owned: std.ArrayList([]const u8) = .empty,
    /// Imported module ASTs (own their arenas). Freed in `deinit`.
    module_docs: std.ArrayList(*ast.Document) = .empty,
    type_of_results: std.AutoHashMap(*ast.Node, []const u8),
    last_emitted_line: i32 = -1,
    last_emitted_column: i32 = -1,
    /// When true, bare struct/array literals use immortal heap (globals / return of literals).
    alloc_immortal: bool = false,
    /// Last AST location seen while compiling — used when a CompileError has no explicit loc.
    diag_path: []const u8 = "",
    diag_line: u32 = 0,
    diag_column: u32 = 0,
    /// Active `@import` chain (outermost first). Used while loading modules.
    import_stack: std.ArrayList(ImportFrame) = .empty,
    /// Resolved module path → import site that loaded it (survives after load for compile errors).
    import_from: std.StringHashMap(ImportFrame),
};

pub fn create(allocator: std.mem.Allocator) !CompilerState {
    var state: CompilerState = .{
        .allocator = allocator,
        .chunk = chunk_mod.Chunk.init(allocator),
        .functions = std.StringHashMap(FunctionDef).init(allocator),
        .structs = std.StringHashMap(StructDef).init(allocator),
        .enums = std.StringHashMap(EnumDef).init(allocator),
        .defer_stacks = std.AutoHashMap(i32, std.ArrayListUnmanaged(DeferEntry)).init(allocator),
        .global_vars = std.StringHashMap(void).init(allocator),
        .global_types = std.StringHashMap([]const u8).init(allocator),
        .global_consts = std.StringHashMap(void).init(allocator),
        .ready_global_consts = std.StringHashMap(void).init(allocator),
        .native_globals = std.StringHashMap(void).init(allocator),
        .global_slots = std.StringHashMap(u16).init(allocator),
        .type_of_results = std.AutoHashMap(*ast.Node, []const u8).init(allocator),
        .import_from = std.StringHashMap(ImportFrame).init(allocator),
    };
    try state.native_globals.put("print", {});
    try state.native_globals.put("error", {});
    try state.native_globals.put("len", {});
    try state.native_globals.put("__printLn", {});
    try state.native_globals.put("__hostLog", {});
    try putStruct(&state, "string", &.{ .{ "ptr", "int" }, .{ "len", "int" } });
    try putStruct(&state, "error", &.{.{ "message", "string" }});
    return state;
}

fn putStruct(state: *CompilerState, name: []const u8, fields: []const struct { []const u8, []const u8 }) !void {
    const layout = @import("layout.zig");
    var types = std.StringHashMap([]const u8).init(state.allocator);
    var specs: std.ArrayList(layout.FieldSpec) = .empty;
    defer specs.deinit(state.allocator);
    for (fields) |f| {
        try types.put(f[0], f[1]);
        try specs.append(state.allocator, .{ .name = f[0], .type_name = f[1] });
    }
    const laid = try layout.layoutFields(state.allocator, specs.items);
    try state.structs.put(name, .{ .name = name, .size = laid.size, .offsets = laid.offsets, .types = types });
}

/// Free compiler tables. Does **not** free `chunk` — caller owns it after `compile`.
pub fn deinit(self: *CompilerState) void {
    for (self.module_docs.items) |mod_doc| {
        mod_doc.deinit();
        self.allocator.destroy(mod_doc);
    }
    self.module_docs.deinit(self.allocator);
    for (self.owned.items) |s| self.allocator.free(s);
    self.owned.deinit(self.allocator);
    self.locals.deinit(self.allocator);
    for (self.loops.items) |*loop| {
        loop.break_jumps.deinit(self.allocator);
        loop.continue_jumps.deinit(self.allocator);
    }
    self.loops.deinit(self.allocator);
    for (self.exprs.items) |*ex| {
        ex.break_jumps.deinit(self.allocator);
    }
    self.exprs.deinit(self.allocator);
    var fit = self.functions.iterator();
    while (fit.next()) |e| {
        e.value_ptr.calls.deinit();
        e.value_ptr.forward_jumps.deinit(self.allocator);
    }
    self.functions.deinit();
    var sit = self.structs.iterator();
    while (sit.next()) |e| {
        e.value_ptr.offsets.deinit();
        e.value_ptr.types.deinit();
    }
    self.structs.deinit();
    var eit = self.enums.iterator();
    while (eit.next()) |e| {
        e.value_ptr.variants.deinit();
    }
    self.enums.deinit();
    var dit = self.defer_stacks.iterator();
    while (dit.next()) |e| e.value_ptr.deinit(self.allocator);
    self.defer_stacks.deinit();
    for (self.inline_return_jumps.items) |*j| j.deinit(self.allocator);
    self.inline_return_jumps.deinit(self.allocator);
    self.global_vars.deinit();
    self.global_types.deinit();
    self.global_consts.deinit();
    self.ready_global_consts.deinit();
    self.native_globals.deinit();
    self.global_slots.deinit();
    self.type_of_results.deinit();
    self.import_stack.deinit(self.allocator);
    self.import_from.deinit();
}

pub fn currentChunk(state: *CompilerState) *chunk_mod.Chunk {
    return &state.chunk;
}
