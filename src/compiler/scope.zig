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
    try emitScopeDefers(state, state.scope_depth, .normal);
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
    if (std.mem.startsWith(u8, name, "__") or
        state.global_vars.contains(name) or
        state.global_consts.contains(name) or
        state.functions.contains(name) or
        state.native_globals.contains(name))
    {
        // Variable is known
    } else {
        var buf: [256]u8 = undefined;
        const type_key = std.fmt.bufPrint(&buf, "${s}", .{name}) catch "";
        if (!state.global_types.contains(type_key)) {
            std.debug.print("CompileError: Unknown identifier '{s}'\n", .{name});
            return error.CompileError;
        }
    }
    if (state.functions.contains(name)) {
        try emit.emitNameGet(state, .OP_GET_FUNCTION, name);
    } else {
        try emit.emitNameGet(state, .OP_GET_GLOBAL, name);
    }
}

pub fn pushDefer(state: *CompilerState, node: *ast.Node, is_errdefer: bool) !void {
    var entry = try state.defer_stacks.getOrPut(state.scope_depth);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
    }
    try entry.value_ptr.append(state.allocator, .{ .body = node, .is_errdefer = is_errdefer });
}

pub const ExitKind = enum { normal, error_path, dynamic };

pub fn emitFunctionExitDefers(state: *CompilerState, kind: ExitKind) !void {
    var d: i32 = state.scope_depth;
    while (d >= 1) : (d -= 1) {
        try emitScopeDefers(state, d, kind);
    }
}

pub fn emitDefersUntil(state: *CompilerState, target_depth: i32, kind: ExitKind) !void {
    var d: i32 = state.scope_depth;
    while (d > target_depth) : (d -= 1) {
        try emitScopeDefers(state, d, kind);
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

fn emitScopeDefers(state: *CompilerState, depth: i32, kind: ExitKind) !void {
    const list = state.defer_stacks.getPtr(depth) orelse return;
    if (list.items.len == 0) return;
    const stmt = @import("stmt/root.zig");
    var i: isize = @intCast(list.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const defer_entry = list.items[@intCast(i)];
        const stmt_node = defer_entry.body;
        const is_errdefer = defer_entry.is_errdefer;
        
        switch (kind) {
            .normal => if (is_errdefer) continue,
            .error_path => {},
            .dynamic => {
                if (is_errdefer) {
                    try emit.emitOp(state, .OP_DUP);
                    try emit.emitOp(state, .OP_IS_ERROR);
                    const skip = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
                    try emit.emitOp(state, .OP_POP);
                    try stmt.compileStatement(state, stmt_node);
                    const jump_end = try emit.emitJump(state, .OP_JUMP);
                    emit.patchJump(state, skip);
                    try emit.emitOp(state, .OP_POP);
                    emit.patchJump(state, jump_end);
                    continue;
                }
            },
        }
        try stmt.compileStatement(state, stmt_node);
    }
    // Only clear if it's a permanent exit (not a break/continue/return from within).
    // Actually, `emitScopeDefers` clears the list today, which is WRONG if called from `break`!
    // We should not clear it if we are just walking up the stack for a jump.
    // Wait, the original code had `list.clearRetainingCapacity()`. We'll just remove it for now and clear in `endScope`.
}
