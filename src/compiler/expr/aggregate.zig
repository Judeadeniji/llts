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
    if (err.payload) |p| {
        try expr.compileExpression(state, p);
        try emit.emitOp(state, .OP_MAKE_ERROR_PAYLOAD);
    } else {
        try emit.emitOp(state, .OP_MAKE_ERROR);
    }
}

pub fn compileTry(state: *CompilerState, try_expr: *const ast.TryExpr) !void {
    // Compile-time: '?' requires an error-union (or unknown) operand.
    if (types.resolveType(state, try_expr.expression)) |disp| {
        if (!types.typeAllowsError(disp)) {
                        return @import("../../errors/compile.zig").compileFailFmt(state, "'?' operator used on non-error-union type '{s}'", .{disp});
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
    // Frame-local `__alloc` by default; `__allocImmortal` for globals / returned literals.
    const length: i32 = @intCast(arr.elements.len);
    const alloc = if (state.alloc_immortal) "__allocImmortal" else "__alloc";
    try emit.emitNameGet(state, .OP_GET_GLOBAL, alloc);
    try emit.emitConstant(state, .{ .int = length + 1 });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try fillArray(state, arr);
}

pub fn compileStructInit(state: *CompilerState, init: *const ast.StructInit) !void {
    const struct_def = try resolveStructDef(state, init);
    // Frame bump by default; immortal for module/globals and returned literals (escape.zig).
    const alloc = if (state.alloc_immortal) "__allocImmortal" else "__alloc";
    try emit.emitNameGet(state, .OP_GET_GLOBAL, alloc);
    try emit.emitConstant(state, .{ .int = struct_def.size });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try fillStruct(state, init, struct_def);
}

/// `@new(allocator, Type | Foo{…} | […])` — allocate into a library Allocator (Arena).
/// Type form zero-defaults; result is Pass-colored and may be returned / freed via arena.reset.
/// Runtime-sized: `@new(a, []T, n)` or `@new(a, string, n)`.
pub fn compileNew(state: *CompilerState, c: *const ast.Call) !void {
    if (c.args.len != 2 and c.args.len != 3) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "@new expects (allocator, type_or_value) or (allocator, []T|string, length)", .{});
    }
    const value = c.args[1];
    switch (value.*) {
        .struct_init => |*init| {
            if (c.args.len != 2) {
                return @import("../../errors/compile.zig").compileFailFmt(state, "@new struct literal takes (allocator, value)", .{});
            }
            const struct_def = try resolveStructDef(state, init);
            try emitArenaAlloc(state, c.args[0], struct_def.size);
            try fillStruct(state, init, struct_def);
        },
        .array_literal => |*arr| {
            if (c.args.len != 2) {
                return @import("../../errors/compile.zig").compileFailFmt(state, "@new array literal takes (allocator, value)", .{});
            }
            const length: i32 = @intCast(arr.elements.len);
            try emitArenaAlloc(state, c.args[0], length + 1);
            try fillArray(state, arr);
        },
        .array_type => |*at| {
            if (at.length) |length| {
                if (c.args.len != 2) {
                    return @import("../../errors/compile.zig").compileFailFmt(state, "@new([N]T) takes (allocator, [N]T) — length is in the type", .{});
                }
                try emitArenaAlloc(state, c.args[0], @intCast(length + 1));
                try zeroFillArray(state, @intCast(length), at.elem);
            } else {
                if (c.args.len != 3) {
                    return @import("../../errors/compile.zig").compileFailFmt(state, "@new slice type needs a length: @new(allocator, []T, n)", .{});
                }
                try requireSimpleElemType(state, at.elem);
                try emitArenaAllocArray(state, c.args[0], c.args[2]);
            }
        },
        .primary => |p| {
            if (p.kind != .identifier) {
                return @import("../../errors/compile.zig").compileFailFmt(state, "@new type must be a struct, string, or array type", .{});
            }
            if (isStringyTypeName(p.name)) {
                if (c.args.len != 3) {
                    return @import("../../errors/compile.zig").compileFailFmt(state, "@new string/[]byte needs a length: @new(allocator, string, n)", .{});
                }
                try emitArenaAllocArray(state, c.args[0], c.args[2]);
                return;
            }
            if (c.args.len != 2) {
                return @import("../../errors/compile.zig").compileFailFmt(state, "@new struct type takes (allocator, Type)", .{});
            }
            var struct_name = p.name;
            if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
                struct_name = try path.resolveModuleType(state, struct_name);
            }
            const struct_def = state.structs.get(struct_name) orelse {
                return @import("../../errors/compile.zig").compileFailFmt(state, "@new unknown type '{s}'", .{p.name});
            };
            try emitArenaAlloc(state, c.args[0], struct_def.size);
            try zeroFillStruct(state, struct_def);
        },
        else => {
            return @import("../../errors/compile.zig").compileFailFmt(state, "@new expects a type, struct literal, or array literal", .{});
        },
    }
}

fn isStringyTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "[]byte");
}

fn requireSimpleElemType(state: *CompilerState, elem_type: *ast.Node) !void {
    switch (elem_type.*) {
        .primary => |p| {
            if (std.mem.eql(u8, p.name, "byte") or std.mem.eql(u8, p.name, "int") or
                std.mem.eql(u8, p.name, "i32") or std.mem.eql(u8, p.name, "number"))
                return;
            return @import("../../errors/compile.zig").compileFailFmt(state, "@new([]T, n) currently supports byte/int elements, got '{s}'", .{p.name});
        },
        else => {
            return @import("../../errors/compile.zig").compileFailFmt(state, "@new([]T, n) element type must be a simple name", .{});
        },
    }
}

fn emitArenaAlloc(state: *CompilerState, allocator_expr: *ast.Node, slots: i32) !void {
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc");
    try expr.compileExpression(state, allocator_expr);
    try emit.emitConstant(state, .{ .int = slots });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 2);
}

fn emitArenaAllocArray(state: *CompilerState, allocator_expr: *ast.Node, length_expr: *ast.Node) !void {
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc_array");
    try expr.compileExpression(state, allocator_expr);
    try expr.compileExpression(state, length_expr);
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 2);
}

fn zeroFillArray(state: *CompilerState, length: i32, elem_type: *ast.Node) !void {
    try emit.emitOp(state, .OP_DUP);
    try emit.emitConstant(state, .{ .int = 0 });
    try emit.emitConstant(state, .{ .int = length });
    try emit.emitOp(state, .OP_SET_INDEX);
    try emit.emitOp(state, .OP_POP);
    try emit.emitConstant(state, .{ .int = 1 });
    try emit.emitOp(state, .OP_ADD);
    var i: i32 = 0;
    while (i < length) : (i += 1) {
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .int = i });
        try emitZeroForElemType(state, elem_type);
        try emit.emitOp(state, .OP_SET_INDEX);
        try emit.emitOp(state, .OP_POP);
    }
}

fn zeroFillStruct(state: *CompilerState, struct_def: state_mod.StructDef) !void {
    var it = struct_def.offsets.iterator();
    while (it.next()) |e| {
        const offset = e.value_ptr.*;
        const field_ty = struct_def.types.get(e.key_ptr.*) orelse "int";
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .int = offset });
        try emitZeroForTypeName(state, field_ty);
        try emit.emitOp(state, .OP_SET_INDEX);
        try emit.emitOp(state, .OP_POP);
    }
}

fn emitZeroForElemType(state: *CompilerState, elem_type: *ast.Node) !void {
    switch (elem_type.*) {
        .primary => |p| try emitZeroForTypeName(state, p.name),
        else => {
            return @import("../../errors/compile.zig").compileFailFmt(state, "@new element type must be a simple named type", .{});
        },
    }
}

fn emitZeroForTypeName(state: *CompilerState, name: []const u8) !void {
    if (std.mem.eql(u8, name, "float")) {
        try emit.emitConstant(state, .{ .float = 0 });
        return;
    }
    if (std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "boolean")) {
        try emit.emitOp(state, .OP_FALSE);
        return;
    }
    if (std.mem.eql(u8, name, "null")) {
        try emit.emitOp(state, .OP_NULL);
        return;
    }
    // int / byte / stringy headers / unknown scalars → 0
    if (state.structs.contains(name)) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "@new cannot zero nested struct field of type '{s}' yet", .{name});
    }
    try emit.emitConstant(state, .{ .int = 0 });
}

fn resolveStructDef(state: *CompilerState, init: *const ast.StructInit) !state_mod.StructDef {
    var struct_name = init.name;
    if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
        struct_name = try path.resolveModuleType(state, struct_name);
        if (!state.chunk.exports.contains(struct_name)) {
            if (std.mem.indexOfScalar(u8, init.name, '.')) |dot| {
                return @import("../../errors/compile.zig").compileFailFmt(state, "'{s}' has no export '{s}'", .{ init.name[0..dot], init.name[dot + 1 ..] });
            } else {
                return @import("../../errors/compile.zig").compileFailFmt(state, "Unknown struct: {s}", .{init.name});
            }
        }
    }
    return state.structs.get(struct_name) orelse {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Unknown struct: {s}", .{init.name});
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
                        return @import("../../errors/compile.zig").compileFailFmt(state, "Unknown field {s}", .{field.name});
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
                                return @import("../../errors/compile.zig").compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_name, prop_name });
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
                        return @import("../../errors/compile.zig").compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_name, short });
        }
    }

    const value = ed.variants.get(variant) orelse {
                return @import("../../errors/compile.zig").compileFailFmt(state, "Unknown enum variant '{s}' on '{s}'", .{ variant, ename });
    };
    try emit.emitConstant(state, .{ .int = value });
    return true;
}
