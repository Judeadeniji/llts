const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const path = @import("path.zig");
const types = @import("../typecheck/from_ast.zig");
const compiler_errors = @import("../../errors/compile.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileIndex(state: *CompilerState, idx: *const ast.Index) !void {
    try expr.compileExpression(state, idx.object);
    if (idx.is_slice) {
        if (idx.index) |start| {
            try expr.compileExpression(state, start);
        } else {
            try emit.emitConstant(state, .{ .i64 = 0 });
        }
        if (idx.end) |end| {
            try expr.compileExpression(state, end);
        } else {
            // Null end → runtime uses object length.
            try emit.emitOp(state, .OP_NULL);
        }
        try emit.emitOp(state, .OP_SLICE);
    } else {
        const start = idx.index orelse {
            return compiler_errors.compileFailFmt(state, "Expected index expression", .{});
        };
        try expr.compileExpression(state, start);
        try emit.emitOp(state, .OP_GET_ARRAY);
    }
}

pub fn compileError(state: *CompilerState, err: *const ast.ErrorExpr) !void {
    try expr.compileExpression(state, err.args[0]);
    if (err.args.len == 2) {
        try expr.compileExpression(state, err.args[1]);
        try emit.emitOp(state, .OP_MAKE_ERROR_PAYLOAD);
    } else {
        try emit.emitOp(state, .OP_MAKE_ERROR);
    }
}

pub fn compileTry(state: *CompilerState, try_expr: *const ast.TryExpr) !void {
    // Compile-time: '?' requires an error-union (or unknown) operand.
    if (types.resolveType(state, try_expr.expression)) |disp| {
        if (!types.typeAllowsError(disp)) {
            return compiler_errors.compileFailFmt(state, "'?' operator used on non-error-union type '{s}'", .{disp});
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
    const length: i32 = @intCast(arr.elements.len);
    const alloc = if (state.alloc_immortal) "__allocImmortalArray" else "__allocArray";
    try emit.emitNameGet(state, .OP_GET_GLOBAL, alloc);
    try emit.emitConstant(state, .{ .i64 = length });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try fillArray(state, arr);
}

pub fn compileStructInit(state: *CompilerState, init: *const ast.StructInit) !void {
    const struct_def = try resolveStructDef(state, init);
    // Frame bump by default; immortal for module/globals and returned literals (escape.zig).
    const alloc = if (state.alloc_immortal) "__allocImmortalBytes" else "__allocBytes";
    try emit.emitNameGet(state, .OP_GET_GLOBAL, alloc);
    try emit.emitConstant(state, .{ .i64 = struct_def.size });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    try fillStruct(state, init, struct_def);
}

/// `@new(allocator, Type | Foo{…} | […])` — allocate into a library Allocator (Arena).
/// Type form zero-defaults; result is Pass-colored and may be returned / freed via arena.reset.
/// Runtime-sized: `@new(a, []T, n)` or `@new(a, string, n)`.
pub fn compileNew(state: *CompilerState, c: *const ast.Call) !void {
    if (c.args.len != 2 and c.args.len != 3) {
        return compiler_errors.compileFailFmt(state, "@new expects (allocator, type_or_value) or (allocator, []T|string, length)", .{});
    }
    const value = c.args[1];
    switch (value.*) {
        .struct_init => |*init| {
            if (c.args.len != 2) {
                return compiler_errors.compileFailFmt(state, "@new struct literal takes (allocator, value)", .{});
            }
            const struct_def = try resolveStructDef(state, init);
            try emitArenaAllocBytes(state, c.args[0], null, struct_def.size);
            try fillStruct(state, init, struct_def);
        },
        .array_literal => |*arr| {
            if (c.args.len != 2) {
                return compiler_errors.compileFailFmt(state, "@new array literal takes (allocator, value)", .{});
            }
            const length: i32 = @intCast(arr.elements.len);
            try emitArenaAllocArray(state, c.args[0], null, length);
            try fillArray(state, arr);
        },
        .array_type => |*at| {
            if (at.length_text) |text| {
                const length = types.parseArrayLengthString(text) catch {
                    return compiler_errors.compileFailFmt(state, "Invalid array length '{s}'", .{text});
                };
                if (c.args.len != 2) {
                    return compiler_errors.compileFailFmt(state, "@new([N]T) takes (allocator, [N]T) — length is in the type", .{});
                }
                if (isByteElemType(at.elem)) {
                    try emitArenaAllocBytes(state, c.args[0], null, @intCast(length));
                } else {
                    try emitArenaAllocArray(state, c.args[0], null, @intCast(length));
                    try zeroFillArray(state, @intCast(length), at.elem);
                }
            } else {
                if (c.args.len != 3) {
                    return compiler_errors.compileFailFmt(state, "@new slice type needs a length: @new(allocator, []T, n)", .{});
                }
                try requireSimpleElemType(state, at.elem);
                if (isByteElemType(at.elem)) {
                    try emitArenaAllocBytes(state, c.args[0], c.args[2], null);
                } else {
                    try emitArenaAllocArray(state, c.args[0], c.args[2], null);
                }
            }
        },
        .primary => |p| {
            if (p.kind != .identifier) {
                return compiler_errors.compileFailFmt(state, "@new type must be a struct, string, or array type", .{});
            }
            if (isStringyTypeName(p.name)) {
                if (c.args.len != 3) {
                    return compiler_errors.compileFailFmt(state, "@new string/[]byte needs a length: @new(allocator, string, n)", .{});
                }
                try emitArenaAllocBytes(state, c.args[0], c.args[2], null);
                return;
            }
            if (c.args.len != 2) {
                return compiler_errors.compileFailFmt(state, "@new struct type takes (allocator, Type)", .{});
            }
            var struct_name = p.name;
            if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
                struct_name = try path.resolveModuleType(state, struct_name);
            }
            const struct_def = state.structs.get(struct_name) orelse {
                return compiler_errors.compileFailFmt(state, "@new unknown type '{s}'", .{p.name});
            };
            try emitArenaAllocBytes(state, c.args[0], null, struct_def.size);
            try zeroFillStruct(state, struct_def);
        },
        else => {
            return compiler_errors.compileFailFmt(state, "@new expects a type, struct literal, or array literal", .{});
        },
    }
}

fn isStringyTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "[]byte");
}

fn isByteElemType(elem_type: *ast.Node) bool {
    return elem_type.* == .primary and (std.mem.eql(u8, elem_type.primary.name, "byte") or
        std.mem.eql(u8, elem_type.primary.name, "u8"));
}

fn requireSimpleElemType(state: *CompilerState, elem_type: *ast.Node) !void {
    switch (elem_type.*) {
        .primary => |p| {
            if (std.mem.eql(u8, p.name, "byte") or std.mem.eql(u8, p.name, "int") or
                std.mem.eql(u8, p.name, "i32") or std.mem.eql(u8, p.name, "number"))
                return;
            return compiler_errors.compileFailFmt(state, "@new([]T, n) currently supports byte/int elements, got '{s}'", .{p.name});
        },
        else => {
            return compiler_errors.compileFailFmt(state, "@new([]T, n) element type must be a simple name", .{});
        },
    }
}

fn emitArenaAlloc(state: *CompilerState, allocator_expr: *ast.Node, slots: i32) !void {
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc");
    try expr.compileExpression(state, allocator_expr);
    try emit.emitConstant(state, .{ .i64 = slots });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 2);
}

fn emitArenaAllocArray(state: *CompilerState, allocator_expr: *ast.Node, length_expr: ?*ast.Node, const_len: ?i32) !void {
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc_array");
    try expr.compileExpression(state, allocator_expr);
    if (length_expr) |le| {
        try expr.compileExpression(state, le);
    } else {
        try emit.emitConstant(state, .{ .i64 = const_len orelse 0 });
    }
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 2);
}

fn emitArenaAllocBytes(state: *CompilerState, allocator_expr: *ast.Node, length_expr: ?*ast.Node, const_len: ?i32) !void {
    try emit.emitNameGet(state, .OP_GET_GLOBAL, "__arena_alloc_bytes");
    try expr.compileExpression(state, allocator_expr);
    if (length_expr) |le| {
        try expr.compileExpression(state, le);
    } else {
        try emit.emitConstant(state, .{ .i64 = const_len orelse 0 });
    }
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 2);
}

fn zeroFillArray(state: *CompilerState, length: i32, elem_type: *ast.Node) !void {
    // Elements already zeroed (.null) by alloc; write typed zeros.
    var i: i32 = 0;
    while (i < length) : (i += 1) {
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .i64 = i });
        try emitZeroForElemType(state, elem_type);
        try emit.emitOp(state, .OP_SET_ARRAY);
        try emit.emitOp(state, .OP_POP);
    }
}

fn zeroFillStruct(state: *CompilerState, struct_def: state_mod.StructDef) !void {
    const layout = @import("../layout.zig");
    var it = struct_def.offsets.iterator();
    while (it.next()) |e| {
        const offset = e.value_ptr.*;
        const field_ty = struct_def.types.get(e.key_ptr.*) orelse "int";
        const kind: u8 = @intFromEnum(layout.fieldKind(state, field_ty));
        try emit.emitOp(state, .OP_DUP);
        try emitZeroForTypeName(state, field_ty);
        try emit.emitStoreField(state, offset, kind);
        try emit.emitOp(state, .OP_POP);
    }
}

fn emitZeroForElemType(state: *CompilerState, elem_type: *ast.Node) !void {
    switch (elem_type.*) {
        .primary => |p| try emitZeroForTypeName(state, p.name),
        else => {
            return compiler_errors.compileFailFmt(state, "@new element type must be a simple named type", .{});
        },
    }
}

fn emitZeroForTypeName(state: *CompilerState, name: []const u8) !void {
    const layout = @import("../layout.zig");
    if (std.mem.eql(u8, name, "float") or std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "f32")) {
        try emit.emitConstant(state, .{ .f64 = 0 });
        return;
    }
    if (std.mem.eql(u8, name, "u1") or std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "boolean")) {
        try emit.emitOp(state, .OP_FALSE);
        return;
    }
    if (std.mem.eql(u8, name, "null")) {
        try emit.emitOp(state, .OP_NULL);
        return;
    }
    switch (layout.fieldKind(state, name)) {
        .handle, .ptr => try emit.emitOp(state, .OP_NULL),
        .i64, .f64, .f32, .u1, .u8, .i8, .i16, .i32, .u16, .u32, .u64 => try emit.emitConstant(state, .{ .i64 = 0 }),
    }
}

fn resolveStructDef(state: *CompilerState, init: *const ast.StructInit) !state_mod.StructDef {
    const sn = types.resolveStructName(state, init.type_expr) orelse {
        return compiler_errors.compileFailFmt(state, "Invalid struct initialization type", .{});
    };
    var struct_name = sn;
    if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
        struct_name = try path.resolveModuleType(state, struct_name);
    }
    try types.checkStructInitExport(state, init.type_expr, struct_name);
    return state.structs.get(struct_name) orelse {
        return compiler_errors.compileFailFmt(state, "Unknown struct: {s}", .{sn});
    };
}

fn fillArray(state: *CompilerState, arr: *const ast.ArrayLiteral) !void {
    for (arr.elements, 0..) |el, i| {
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .i64 = @intCast(i) });
        try expr.compileExpression(state, el);
        try emit.emitOp(state, .OP_SET_ARRAY);
        try emit.emitOp(state, .OP_POP);
    }
}

fn fillStruct(state: *CompilerState, init: *const ast.StructInit, struct_def: state_mod.StructDef) !void {
    const layout = @import("../layout.zig");
    for (init.fields) |field| {
        const offset = struct_def.offsets.get(field.name) orelse {
            return compiler_errors.compileFailFmt(state, "Unknown field {s}", .{field.name});
        };
        const field_ty = struct_def.types.get(field.name) orelse "int";
        const kind: u8 = @intFromEnum(layout.fieldKind(state, field_ty));
        try emit.emitOp(state, .OP_DUP);
        try expr.compileExpression(state, field.value);
        try emit.emitStoreField(state, offset, kind);
        try emit.emitOp(state, .OP_POP);
    }
}

pub fn compileMember(state: *CompilerState, mem: *const ast.Member, node: *ast.Node) !void {
    if (try compileEnumVariant(state, mem)) return;

    // Tuple field `.0` / `.1` — same runtime as array index.
    if (mem.property.* == .primary) {
        if (std.fmt.parseInt(i64, mem.property.primary.name, 10)) |idx| {
            try expr.compileExpression(state, mem.object);
            try emit.emitConstant(state, .{ .i64 = idx });
            try emit.emitOp(state, .OP_GET_ARRAY);
            return;
        } else |_| {}
    }

    if (try path.tryResolveStaticPath(state, node)) |static_path| {
        if (std.mem.indexOf(u8, static_path, "::") != null) {
            var buf: [512]u8 = undefined;
            const re_key = std.fmt.bufPrint(&buf, "${s}", .{static_path}) catch "";
            const re = state.global_types.get(re_key);
            const is_reexport = if (re) |r| std.mem.startsWith(u8, r, "module:") else false;
            if (!state.chunk.exports.contains(static_path) and !is_reexport) {
                const mod_name = if (mem.object.* == .primary) mem.object.primary.name else "Module";
                const prop_name = if (mem.property.* == .primary) mem.property.primary.name else "property";
                return compiler_errors.compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_name, prop_name });
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
        if (mem.property.* == .primary) {
            if (types.lookupStructField(state, type_name, mem.property.primary.name)) |info| {
                const layout = @import("../layout.zig");
                const kind: u8 = @intFromEnum(layout.fieldKind(state, info.field_ty));
                try expr.compileExpression(state, mem.object);
                try emit.emitLoadField(state, info.offset, kind);
                return;
            }
        }
        if (types.lookupStruct(state, type_name)) |sd| {
            if (mem.property.* == .primary) {
                if (sd.offsets.get(mem.property.primary.name)) |offset| {
                    const layout = @import("../layout.zig");
                    const field_ty = sd.types.get(mem.property.primary.name) orelse "int";
                    const kind: u8 = @intFromEnum(layout.fieldKind(state, field_ty));
                    try expr.compileExpression(state, mem.object);
                    try emit.emitLoadField(state, offset, kind);
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
            return compiler_errors.compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_name, short });
        }
    }

    const value = ed.variants.get(variant) orelse {
        return compiler_errors.compileFailFmt(state, "Unknown enum variant '{s}' on '{s}'", .{ variant, ename });
    };
    try emit.emitConstant(state, .{ .i64 = value });
    return true;
}
