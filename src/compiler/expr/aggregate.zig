const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const path = @import("path.zig");
const types = @import("../typecheck/from_ast.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileIndex(state: *CompilerState, idx: *const ast.Index) !void {
    try expr.compileExpression(state, idx.object);
    try expr.compileExpression(state, idx.index);
    try emit.emitOp(state, .OP_GET_ARRAY);
}

pub fn compileError(state: *CompilerState, err: *const ast.ErrorExpr) !void {
    try expr.compileExpression(state, err.message);
    try emit.emitOp(state, .OP_MAKE_ERROR);
}

pub fn compileTry(state: *CompilerState, try_expr: *const ast.TryExpr) !void {
    // Compile-time: '?' requires an error-union (or unknown) operand.
    if (types.resolveType(state, try_expr.expression)) |disp| {
        if (!types.typeAllowsError(disp)) {
            std.debug.print("CompileError: '?' operator used on non-error-union type '{s}'\n", .{disp});
            return error.CompileError;
        }
    }
    try expr.compileExpression(state, try_expr.expression);
    try emit.emitOp(state, .OP_DUP);
    try emit.emitOp(state, .OP_IS_ERROR);
    const skip_ret = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);
    try scope.emitFunctionExitDefers(state, .error_path);
    try emit.emitOp(state, .OP_RETURN);
    emit.patchJump(state, skip_ret);
    try emit.emitOp(state, .OP_POP);
}

pub fn compileArray(state: *CompilerState, arr: *const ast.ArrayLiteral) !void {
    // Frame-local: uses `__alloc` (rewound on return). Prefer `@new(a, […])` to escape.
    const length: i32 = @intCast(arr.elements.len);
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__alloc");
    try emit.emitConstant(state, .{ .int = length + 1 });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try fillArray(state, arr);
}

pub fn compileStructInit(state: *CompilerState, init: *const ast.StructInit) !void {
    const struct_def = try resolveStructDef(state, init);
    // Frame-local bump — cannot be returned (escape.zig). Use `@new(arena, …)` to escape.
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__alloc");
    try emit.emitConstant(state, .{ .int = struct_def.size });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try fillStruct(state, init, struct_def);
}

/// `@new(allocator, Foo{…}|[…])` — allocate into a library Allocator (Arena).
/// Result is Pass-colored and may be returned from the frame.
pub fn compileNew(state: *CompilerState, c: *const ast.Call) !void {
    if (c.args.len != 2) {
        std.debug.print("CompileError: @new expects (allocator, value) — like Go make\n", .{});
        return error.CompileError;
    }
    const value = c.args[1];
    switch (value.*) {
        .struct_init => |*init| {
            const struct_def = try resolveStructDef(state, init);
            // stack: __arena_alloc, allocator, size → call → ptr
            try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc");
            try expr.compileExpression(state, c.args[0]);
            try emit.emitConstant(state, .{ .int = struct_def.size });
            try emit.emitOp(state, .OP_CALL);
            try emit.emitByte(state, 2);
            try fillStruct(state, init, struct_def);
        },
        .array_literal => |*arr| {
            const length: i32 = @intCast(arr.elements.len);
            try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc");
            try expr.compileExpression(state, c.args[0]);
            try emit.emitConstant(state, .{ .int = length + 1 });
            try emit.emitOp(state, .OP_CALL);
            try emit.emitByte(state, 2);
            try fillArray(state, arr);
        },
        else => {
            std.debug.print("CompileError: @new value must be a struct or array literal\n", .{});
            return error.CompileError;
        },
    }
}

fn resolveStructDef(state: *CompilerState, init: *const ast.StructInit) !state_mod.StructDef {
    var struct_name = init.name;
    if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
        struct_name = try path.resolveModuleType(state, struct_name);
        if (!state.chunk.exports.contains(struct_name)) {
            if (std.mem.indexOfScalar(u8, init.name, '.')) |dot| {
                std.debug.print("CompileError: '{s}' has no export '{s}'\n", .{ init.name[0..dot], init.name[dot + 1 ..] });
            } else {
                std.debug.print("CompileError: Unknown struct: {s}\n", .{init.name});
            }
            return error.CompileError;
        }
    }
    return state.structs.get(struct_name) orelse {
        std.debug.print("CompileError: Unknown struct: {s}\n", .{init.name});
        return error.CompileError;
    };
}

fn fillArray(state: *CompilerState, arr: *const ast.ArrayLiteral) !void {
    const length: i32 = @intCast(arr.elements.len);
    try emit.emitOp(state, .OP_DUP);
    try emit.emitConstant(state, .{ .int = 0 });
    try emit.emitConstant(state, .{ .int = length });
    try emit.emitOp(state, .OP_SET_INDEX);
    try emit.emitOp(state, .OP_POP);
    try emit.emitConstant(state, .{ .int = 1 });
    try emit.emitOp(state, .OP_ADD);
    for (arr.elements, 0..) |el, i| {
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .int = @intCast(i) });
        try expr.compileExpression(state, el);
        try emit.emitOp(state, .OP_SET_INDEX);
        try emit.emitOp(state, .OP_POP);
    }
}

fn fillStruct(state: *CompilerState, init: *const ast.StructInit, struct_def: state_mod.StructDef) !void {
    for (init.fields) |field| {
        const offset = struct_def.offsets.get(field.name) orelse {
            std.debug.print("CompileError: Unknown field {s}\n", .{field.name});
            return error.CompileError;
        };
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .int = offset });
        try expr.compileExpression(state, field.value);
        try emit.emitOp(state, .OP_SET_INDEX);
        try emit.emitOp(state, .OP_POP);
    }
}

pub fn compileMember(state: *CompilerState, mem: *const ast.Member, node: *ast.Node) !void {
    if (try compileEnumVariant(state, mem)) return;

    if (try path.tryResolveStaticPath(state, node)) |static_path| {
        if (std.mem.indexOf(u8, static_path, "::") != null) {
            var buf: [512]u8 = undefined;
            const re_key = std.fmt.bufPrint(&buf, "${s}", .{static_path}) catch "";
            const re = state.global_types.get(re_key);
            const is_reexport = if (re) |r| std.mem.startsWith(u8, r, "module:") else false;
            if (!state.chunk.exports.contains(static_path) and !is_reexport) {
                const mod_name = if (mem.object.* == .primary) mem.object.primary.name else "Module";
                const prop_name = if (mem.property.* == .primary) mem.property.primary.name else "property";
                std.debug.print("CompileError: '{s}' has no export '{s}'\n", .{ mod_name, prop_name });
                return error.CompileError;
            }
        }
        if (state.functions.contains(static_path)) {
            try emit.emitNameGet(state, .OP_GET_FUNCTION, static_path);
        } else if (std.mem.endsWith(u8, static_path, ".lls")) {
            try emit.emitNameGet(state, .OP_GET_MODULE, static_path);
        } else {
            try emit.emitNameGet(state, .OP_GET_GLOBAL, static_path);
        }
        return;
    }
    if (types.resolveType(state, mem.object)) |type_name| {
        if (state.structs.get(type_name)) |sd| {
            if (mem.property.* == .primary) {
                if (sd.offsets.get(mem.property.primary.name)) |offset| {
                    try expr.compileExpression(state, mem.object);
                    try emit.emitConstant(state, .{ .int = offset });
                    try emit.emitOp(state, .OP_GET_INDEX);
                    return;
                }
            }
        }
    }
    try expr.compileExpression(state, mem.object);
    if (mem.property.* == .primary) {
        try emit.emitNameGet(state, .OP_GET_PROPERTY, mem.property.primary.name);
    }
}

fn compileEnumVariant(state: *CompilerState, mem: *const ast.Member) !bool {
    if (mem.property.* != .primary) return false;
    const variant = mem.property.primary.name;
    const ename = types.resolveEnumName(state, mem.object) orelse return false;
    const ed = state.enums.get(ename) orelse return false;

    // Module-qualified enum access requires a public export.
    if (std.mem.indexOf(u8, ename, "::") != null and mem.object.* == .member) {
        if (!state.chunk.exports.contains(ename)) {
            const mod_name = if (mem.object.member.object.* == .primary)
                mem.object.member.object.primary.name
            else
                "Module";
            const short = if (std.mem.lastIndexOf(u8, ename, "::")) |idx| ename[idx + 2 ..] else ename;
            std.debug.print("CompileError: '{s}' has no export '{s}'\n", .{ mod_name, short });
            return error.CompileError;
        }
    }

    const value = ed.variants.get(variant) orelse {
        std.debug.print("CompileError: Unknown enum variant '{s}' on '{s}'\n", .{ variant, ename });
        return error.CompileError;
    };
    try emit.emitConstant(state, .{ .int = value });
    return true;
}
