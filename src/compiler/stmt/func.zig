const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const stmt = @import("root.zig");
const layout = @import("../layout.zig");

const CompilerState = state_mod.CompilerState;
const from_ast = @import("../typecheck/from_ast.zig");

pub fn compileBlock(state: *CompilerState, block: *const ast.Block) !void {
    try scope.beginScope(state);
    for (block.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);
}

pub fn compileDefer(state: *CompilerState, def: *const ast.Defer) !void {
    try scope.pushDefer(state, def.body, def.is_errdefer);
}

pub fn compileReturn(state: *CompilerState, ret: *const ast.Return) !void {
    if (ret.return_value) |v| {
        const escape = @import("../escape.zig");
        try escape.checkReturnValue(state, v);
        // Bare `return Foo{…}` / `[…]` → immortal (same as module init), not frame bump.
        const prev_immortal = state.alloc_immortal;
        if (escape.canPromoteReturnLiteral(state, v)) state.alloc_immortal = true;
        defer state.alloc_immortal = prev_immortal;
        // Frame-bound deep-cloneable struct → copy into immortal storage so the
        // value outlives the frame without an allocator. Flat scalar structs
        // need only a shallow byte copy; nested value-structs get an unrolled
        // post-order deep clone (children first, then patch parent handles).
        if (escape.canAutoCloneReturn(state, v)) {
            const tn = localTypeOf(state, v).?;
            if (escape.hasNestedStructFields(state, tn)) {
                try emitDeepClone(state, v, tn);
            } else {
                // Flat scalar struct — shallow-copy into immortal.
                try emit.emitNameGet(state, .OP_GET_GLOBAL, "__cloneBytesImmortal");
                try expr.compileExpression(state, v);
                try emit.emitOp(state, .OP_CALL);
                try emit.emitByte(state, 1);
            }
        } else {
            try expr.compileExpression(state, v);
        }
    } else {
        try emit.emitOp(state, .OP_NULL);
    }
    try scope.emitFunctionExitDefers(state, .dynamic);
    if (state.inline_return_jumps.items.len > 0) {
        const patch = try emit.emitJump(state, .OP_JUMP);
        const top = &state.inline_return_jumps.items[state.inline_return_jumps.items.len - 1];
        try top.append(state.allocator, patch);
    } else {
        try emit.emitOp(state, .OP_RETURN);
    }
}

/// Type display of a local identifier/register expression, or null.
fn localTypeOf(state: *CompilerState, node: *ast.Node) ?[]const u8 {
    if (node.* != .primary) return null;
    const p = node.primary;
    if (p.kind != .identifier and p.kind != .register) return null;
    const idx = scope.resolveLocal(state, p.name);
    if (idx < 0) return null;
    return state.locals.items[@intCast(idx)].type_name;
}

/// Emit a deep clone of the frame-bound local named by `v` (type `tn`) into
/// immortal storage. Nested value-struct fields are cloned post-order: each
/// child is loaded from the *source*, deep-cloned, then stored into the
/// parent's shallow-clone shell. Pointer/slice fields never reach here —
/// `canAutoCloneReturn` rejects them.
fn emitDeepClone(state: *CompilerState, v: *ast.Node, tn: []const u8) !void {
    const p = v.primary;
    const src_idx: u8 = @intCast(scope.resolveLocal(state, p.name));
    try emitDeepCloneFromLocal(state, src_idx, tn);
}

/// Emit deep clone of the struct in local `src_idx` of type `tn`.
/// Leaves the clone handle on the stack.
fn emitDeepCloneFromLocal(state: *CompilerState, src_idx: u8, tn: []const u8) !void {
    const escape = @import("../escape.zig");
    // Save compiler locals length so temp slots don't leak into subsequent code.
    const saved_len = state.locals.items.len;
    defer state.locals.shrinkRetainingCapacity(saved_len);

    // Shallow-clone the struct shell into immortal storage → temp .dc_shell.
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__cloneBytesImmortal");
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, src_idx);
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    const shell_idx: u8 = @intCast(state.locals.items.len);
    try state.locals.append(state.allocator, .{ .name = ".dc_shell", .depth = state.scope_depth });

    // For each nested value-struct field: load child from SOURCE, deep-clone,
    // store new handle into the shell.
    const sd = state.structs.get(tn).?;
    var it = sd.types.iterator();
    while (it.next()) |e| {
        const field_name = e.key_ptr.*;
        const field_ty = e.value_ptr.*;
        if (!state.structs.contains(field_ty)) continue;
        if (!escape.isDeepCloneableStruct(state, field_ty, 1)) continue;

        const offset = sd.offsets.get(field_name).?;
        const kind: u8 = @intFromEnum(layout.fieldKind(state, field_ty));

        // Load child handle from SOURCE (not the clone — clone has stale handles).
        try emit.emitOp(state, .OP_GET_LOCAL);
        try emit.emitByte(state, src_idx);
        try emit.emitLoadField(state, offset, kind);
        const child_src_idx: u8 = @intCast(state.locals.items.len);
        try state.locals.append(state.allocator, .{ .name = ".dc_csrc", .depth = state.scope_depth });

        // Deep-clone child (recursively; leaves handle on stack).
        try emitDeepCloneFromLocal(state, child_src_idx, field_ty);
        const child_clone_idx: u8 = @intCast(state.locals.items.len);
        try state.locals.append(state.allocator, .{ .name = ".dc_cclone", .depth = state.scope_depth });

        // Patch: shell.field = child_clone.
        try emit.emitOp(state, .OP_GET_LOCAL);
        try emit.emitByte(state, shell_idx);
        try emit.emitOp(state, .OP_GET_LOCAL);
        try emit.emitByte(state, child_clone_idx);
        try emit.emitStoreField(state, offset, kind);
    }

    // Leave shell on stack for return.
    try emit.emitOp(state, .OP_GET_LOCAL);
    try emit.emitByte(state, shell_idx);
}

pub fn compileFunction(state: *CompilerState, node: *ast.FunctionDecl, ast_node: *ast.Node) !void {
    _ = ast_node;
    const outer_locals = state.locals;
    const outer_depth = state.scope_depth;
    const outer_defers = state.defer_stacks;

    state.locals = .empty;
    state.scope_depth = 0;
    state.defer_stacks = std.AutoHashMap(i32, std.ArrayListUnmanaged(state_mod.DeferEntry)).init(state.allocator);

    try scope.beginScope(state);

    var method_struct: ?[]const u8 = null;
    if (std.mem.lastIndexOf(u8, node.name, "::")) |idx| {
        const sname = node.name[0..idx];
        if (state.structs.contains(sname)) method_struct = sname;
    }

    const params = switch (node.params.*) {
        .params => |*p| p,
        else => return fail(state, "function params malformed"),
    };

    if (params.is_variadic) {
        try emit.emitOp(state, .OP_PACK_REST);
        try emit.emitByte(state, @intCast(if (params.params.len == 0) 0 else params.params.len - 1));
    }

    for (params.params) |p| {
        try pushParam(state, p, method_struct);
    }

    const body = switch (node.body.*) {
        .block => |*b| b,
        else => return fail(state, "function body must be a block"),
    };
    for (body.statements) |s| try stmt.compileStatement(state, s);

    try scope.emitFunctionExitDefers(state, .normal);
    try emit.emitOp(state, .OP_NULL);
    try emit.emitOp(state, .OP_RETURN);

    // discard function-local state
    state.locals.deinit(state.allocator);
    var dit = state.defer_stacks.iterator();
    while (dit.next()) |e| e.value_ptr.deinit(state.allocator);
    state.defer_stacks.deinit();

    state.locals = outer_locals;
    state.scope_depth = outer_depth;
    state.defer_stacks = outer_defers;
}

fn pushParam(state: *CompilerState, p: ast.Param, method_struct: ?[]const u8) !void {
    var p_type: ?[]const u8 = null;
    if (std.mem.eql(u8, p.name, "self")) {
        if (method_struct) |sname| {
            // Unannotated method self defaults to *T (honest mutable receiver).
            const s = try std.fmt.allocPrint(state.allocator, "*{s}", .{sname});
            try state.owned.append(state.allocator, s);
            p_type = s;
        }
    }
    if (p.type_annotation) |ta| {
        p_type = (try from_ast.typeAstToDisplayQualified(ta, state));
    }
    try state.locals.append(state.allocator, .{
        .name = p.name,
        .depth = state.scope_depth,
        .type_name = p_type,
        // Parameters are borrowed for the duration of the call, so allocations
        // from a parameter arena are allowed to escape (Phase 4.1).
        .is_param = true,
    });
}

fn fail(state: *CompilerState, msg: []const u8) error{CompileError} {
    return @import("../../errors/compile.zig").compileFailFmt(state, "{s}", .{msg});
}
