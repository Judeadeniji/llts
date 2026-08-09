const std = @import("std");
const ast = @import("../ast/root.zig");
const emit = @import("emit.zig");
const state_mod = @import("state.zig");

const CompilerState = state_mod.CompilerState;

pub fn beginScope(state: *CompilerState) !void {
    state.scope_depth += 1;
    try state.defer_stacks.put(state.scope_depth, .empty);
}

pub fn endScope(state: *CompilerState) !void {
    try emitScopeDefers(state, state.scope_depth);
    try emitPopsAtDepth(state, state.scope_depth);
    if (state.defer_stacks.fetchRemove(state.scope_depth)) |kv| {
        var list = kv.value;
        list.deinit(state.allocator);
    }
    state.scope_depth -= 1;
}

pub fn addLocal(state: *CompilerState, name: []const u8, is_const: bool) !u8 {
    try state.locals.append(state.allocator, .{
        .name = name,
        .depth = state.scope_depth,
        .is_const = is_const,
    });
    return @intCast(state.locals.items.len - 1);
}

pub fn resolveLocal(state: *CompilerState, name: []const u8) i32 {
    var i: isize = @intCast(state.locals.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const local = state.locals.items[@intCast(i)];
        if (std.mem.eql(u8, local.name, name)) return @intCast(i);
    }
    return -1;
}

pub fn resolveVariable(state: *CompilerState, name: []const u8) !void {
    const arg = resolveLocal(state, name);
    if (arg != -1) {
        try emit.emitOp(state, .OP_GET_LOCAL);
        try emit.emitByte(state, @intCast(arg));
        return;
    }
    // `__` natives are provided by the runtime without an explicit listing.
    const is_native = std.mem.startsWith(u8, name, "__");
    var buf: [256]u8 = undefined;
    const type_key = std.fmt.bufPrint(&buf, "${s}", .{name}) catch "";
    const is_known = is_native or
        state.global_vars.contains(name) or
        state.global_consts.contains(name) or
        state.functions.contains(name) or
        state.native_globals.contains(name) or
        state.global_types.contains(type_key);
    if (!is_known) {
        std.debug.print("CompileError: Unknown identifier '{s}'\n", .{name});
        return error.CompileError;
    }
    if (state.functions.contains(name)) {
        try emit.emitNameGet(state, .OP_GET_FUNCTION, name);
    } else {
        try emit.emitNameGet(state, .OP_GET_GLOBAL, name);
    }
}

pub fn pushDefer(state: *CompilerState, body: *ast.Node) !void {
    const gop = try state.defer_stacks.getOrPut(state.scope_depth);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(state.allocator, body);
}

pub fn emitFunctionExitDefers(state: *CompilerState) !void {
    var d: i32 = state.scope_depth;
    while (d >= 1) : (d -= 1) {
        try emitScopeDefers(state, d);
    }
}

pub fn emitDefersUntil(state: *CompilerState, target_depth: i32) !void {
    var d: i32 = state.scope_depth;
    while (d > target_depth) : (d -= 1) {
        try emitScopeDefers(state, d);
    }
}

/// Emit OP_POP for locals deeper than target_depth without mutating compiler locals.
/// (break/continue must not permanently drop locals — later statements still need them.)
pub fn emitPopsUntil(state: *CompilerState, target_depth: i32) !void {
    var count: usize = 0;
    var i: isize = @intCast(state.locals.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        if (state.locals.items[@intCast(i)].depth > target_depth) {
            count += 1;
        } else break;
    }
    var n: usize = 0;
    while (n < count) : (n += 1) {
        try emit.emitOp(state, .OP_POP);
    }
}

fn emitPopsAtDepth(state: *CompilerState, depth: i32) !void {
    while (state.locals.items.len > 0 and
        state.locals.items[state.locals.items.len - 1].depth == depth)
    {
        _ = state.locals.pop();
        try emit.emitOp(state, .OP_POP);
    }
}

fn emitScopeDefers(state: *CompilerState, depth: i32) !void {
    const list = state.defer_stacks.getPtr(depth) orelse return;
    if (list.items.len == 0) return;
    const stmt = @import("stmt/root.zig");
    var i: isize = @intCast(list.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        try stmt.compileStatement(state, list.items[@intCast(i)]);
    }
    list.clearRetainingCapacity();
}
