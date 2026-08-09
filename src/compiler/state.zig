const std = @import("std");
const chunk_mod = @import("../bytecode/chunk.zig");
const ast = @import("../ast/root.zig");

pub const Local = struct {
    name: []const u8,
    depth: i32,
    type_name: ?[]const u8 = null,
    is_const: bool = false,
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
};

pub const StructDef = struct {
    name: []const u8,
    size: i32,
    offsets: std.StringHashMap(i32),
    types: std.StringHashMap([]const u8),
};

pub const LoopTracker = struct {
    start: usize = 0,
    scope_depth: i32,
    label: ?[]const u8 = null,
    break_jumps: std.ArrayList(usize) = .empty,
    continue_jumps: std.ArrayList(usize) = .empty,
};

pub const CompilerState = struct {
    allocator: std.mem.Allocator,
    chunk: chunk_mod.Chunk,
    debug: bool = true,
    locals: std.ArrayList(Local) = .empty,
    scope_depth: i32 = 0,
    functions: std.StringHashMap(FunctionDef),
    structs: std.StringHashMap(StructDef),
    loops: std.ArrayList(LoopTracker) = .empty,
    defer_stacks: std.AutoHashMap(i32, std.ArrayList(*ast.Node)),
    global_vars: std.StringHashMap(void),
    global_types: std.StringHashMap([]const u8),
    global_consts: std.StringHashMap(void),
    native_globals: std.StringHashMap(void),
    inline_return_jumps: std.ArrayList(std.ArrayList(usize)) = .empty,
    owned: std.ArrayList([]const u8) = .empty,
    /// Imported module ASTs (own their arenas). Freed in `deinit`.
    module_docs: std.ArrayList(*ast.Document) = .empty,
    type_of_results: std.AutoHashMap(*ast.Node, []const u8),
    last_emitted_line: i32 = -1,
};

pub fn create(allocator: std.mem.Allocator) !CompilerState {
    var state: CompilerState = .{
        .allocator = allocator,
        .chunk = chunk_mod.Chunk.init(allocator),
        .functions = std.StringHashMap(FunctionDef).init(allocator),
        .structs = std.StringHashMap(StructDef).init(allocator),
        .defer_stacks = std.AutoHashMap(i32, std.ArrayList(*ast.Node)).init(allocator),
        .global_vars = std.StringHashMap(void).init(allocator),
        .global_types = std.StringHashMap([]const u8).init(allocator),
        .global_consts = std.StringHashMap(void).init(allocator),
        .native_globals = std.StringHashMap(void).init(allocator),
        .type_of_results = std.AutoHashMap(*ast.Node, []const u8).init(allocator),
    };
    try state.native_globals.put("print", {});
    try state.native_globals.put("error", {});
    try state.native_globals.put("len", {});
    try putStruct(&state, "string", &.{ .{ "ptr", "int" }, .{ "len", "int" } });
    try putStruct(&state, "error", &.{.{ "message", "string" }});
    return state;
}

fn putStruct(state: *CompilerState, name: []const u8, fields: []const struct { []const u8, []const u8 }) !void {
    var offsets = std.StringHashMap(i32).init(state.allocator);
    var types = std.StringHashMap([]const u8).init(state.allocator);
    var size: i32 = 0;
    for (fields) |f| {
        try offsets.put(f[0], size);
        try types.put(f[0], f[1]);
        size += 1;
    }
    try state.structs.put(name, .{ .name = name, .size = size, .offsets = offsets, .types = types });
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
    var dit = self.defer_stacks.iterator();
    while (dit.next()) |e| e.value_ptr.deinit(self.allocator);
    self.defer_stacks.deinit();
    for (self.inline_return_jumps.items) |*j| j.deinit(self.allocator);
    self.inline_return_jumps.deinit(self.allocator);
    self.global_vars.deinit();
    self.global_types.deinit();
    self.global_consts.deinit();
    self.native_globals.deinit();
    self.type_of_results.deinit();
}

pub fn currentChunk(state: *CompilerState) *chunk_mod.Chunk {
    return &state.chunk;
}
