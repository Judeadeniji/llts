const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const from_ast = @import("../typecheck/from_ast.zig");
const ir = @import("../typecheck/ir.zig");
const types = @import("../typecheck/from_ast.zig");
const const_expr = @import("../const_expr.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileDeclaration(state: *CompilerState, decl: *const ast.Declaration) !void {
    if (decl.value.* == .call and decl.value.call.callee.* == .primary and std.mem.eql(u8, decl.value.call.callee.primary.name, "@import")) return;

    if (decl.is_const) {
        var cenv = try const_expr.createConstEnv(state);
        defer cenv.deinit();
        // Include locals that are const in current scopes
        for (state.locals.items) |local| {
            if (local.is_const) try cenv.const_names.put(local.name, {});
        }
        if (!const_expr.isConstantExpr(state, &cenv, decl.value)) {
            return @import("../../errors/compile.zig").compileFailFmt(
                state,
                "'{s}' is @const but initializer is not a compile-time constant",
                .{decl.name},
            );
        }
    }

    const is_module_export = std.mem.indexOf(u8, decl.name, "::") != null;
    // Module / top-level values outlive any frame — allocate literals immortally.
    const prev_immortal = state.alloc_immortal;
    if (state.scope_depth == 0 or is_module_export) state.alloc_immortal = true;
    defer state.alloc_immortal = prev_immortal;

    try expr.compileExpression(state, decl.value);

    if (decl.type_annotation) |ta| {
        if (widthCastKind(ta)) |kind| {
            try emit.emitOp(state, .OP_AS);
            try emit.emitByte(state, kind);
        }
    }

    var type_name: ?[]const u8 = null;
    if (decl.type_annotation) |ta| {
        // Prefer type already validated/normalized by the typecheck pass.
        if (state.global_types.get(decl.name)) |gt| {
            type_name = gt;
        } else {
            type_name = try from_ast.typeAstToDisplay(ta, state);
        }
        // Assignability is enforced in typecheck; keep a defensive check for emit-only paths.
        if (types.resolveType(state, decl.value)) |got| {
            if (type_name) |expected| {
                if (!typesAssignable(state, got, expected)) {
                    return @import("../../errors/compile.zig").compileFailFmt(
                        state,
                        "declaration of '{s}': type '{s}' is not assignable to '{s}'",
                        .{ decl.name, got, expected },
                    );
                }
            }
        }
        if (state.debug) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const talloc = ir.TypeAlloc{ .allocator = arena.allocator() };
            const t = try from_ast.typeFromAst(ta, state, talloc);
            if (ir.typeTag(t)) |tag| {
                try emit.emitOp(state, .OP_ASSERT_TYPE);
                try emit.emitByte(state, @intFromEnum(tag));
            }
        }
    } else {
        type_name = if (state.global_types.get(decl.name)) |gt| gt else inferDeclType(state, decl.value);
    }

    if (state.scope_depth > 0 and !is_module_export) {
        try checkLocalDup(state, decl.name);
        try state.locals.append(state.allocator, .{
            .name = decl.name,
            .depth = state.scope_depth,
            .type_name = type_name,
            .is_const = decl.is_const,
            .alloc_region = @import("../escape.zig").regionOfRhs(state, decl.value),
        });
        if (decl.is_const) {
            try emit.emitOp(state, .OP_MARK_CONST);
            try emit.emitByte(state, @intCast(state.locals.items.len - 1));
        }
    } else {
        if (type_name) |tn| try state.global_types.put(decl.name, tn);
        try emit.emitNameGet(state, .OP_SET_GLOBAL, decl.name);
        try emit.emitOp(state, .OP_POP);
        if (decl.is_const) try state.ready_global_consts.put(decl.name, {});
    }
}

fn typesAssignable(state: *CompilerState, got: []const u8, expected: []const u8) bool {
    if (std.mem.eql(u8, got, expected)) return true;
    if (std.mem.eql(u8, expected, "unknown") or std.mem.eql(u8, got, "unknown")) return true;
    if (std.mem.indexOf(u8, got, "unknown") != null or std.mem.indexOf(u8, expected, "unknown") != null) return true;
    // Enum ↔ untyped int (runtime values are ints)
    if (std.mem.eql(u8, got, "int") and state.enums.contains(expected)) return true;
    if ((std.mem.eql(u8, expected, "int") or std.mem.eql(u8, expected, "i64")) and state.enums.contains(got)) return true;
    // Enum.Variant literal type ↔ parent enum / matching variant value display
    if (std.mem.lastIndexOfScalar(u8, expected, '.')) |dot| {
        const ename = expected[0..dot];
        if (state.enums.contains(ename)) {
            if (std.mem.eql(u8, got, ename) or std.mem.eql(u8, got, expected)) return true;
            if (std.mem.eql(u8, got, "int") or std.mem.eql(u8, got, "i64")) return true;
        }
    }
    if (std.mem.lastIndexOfScalar(u8, got, '.')) |dot| {
        const ename = got[0..dot];
        if (state.enums.contains(ename) and std.mem.eql(u8, expected, ename)) return true;
    }
    // string aliases / [N]byte <: []byte
    if (types.isStringyType(got) and types.isStringyType(expected)) {
        // Sized [N]byte is not assignable to [M]byte when N != M
        if (std.mem.startsWith(u8, expected, "[") and expected.len > 1 and expected[1] != ']') {
            // expected is sized
            if (std.mem.startsWith(u8, got, "[") and got.len > 1 and got[1] != ']') {
                return std.mem.eql(u8, got, expected);
            }
            // []byte / string </: [N]byte
            if (std.mem.eql(u8, got, "[]byte") or std.mem.eql(u8, got, "string")) return false;
            return std.mem.eql(u8, got, expected);
        }
        return true;
    }
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };
    const g = from_ast.parseDisplayType(state, ta, got, null) catch return false;
    const e = from_ast.parseDisplayType(state, ta, expected, null) catch return false;
    if (ir.isSubtype(g, e)) return true;
    // Literal-type annotations: value match was checked in typecheck; emit only checks parent shape.
    const ep = ir.peelDefined(e);
    if (literalTypeAcceptsDisplay(ep, got, g)) return true;
    // Untyped integer literal display still spells "int" (not "i64"); may coerce into any integer width,
    // including nested `[N]int` / `[2][3]int` into matching integer arrays.
    if (isUntypedIntDisplay(got) and untypedIntCoerces(g, e)) return true;
    // Untyped / f64 float literal may narrow to f32.
    if ((std.mem.eql(u8, got, "float") or std.mem.eql(u8, got, "f64")) and ir.peelDefined(e) == .f32) return true;
    return false;
}

fn literalTypeAcceptsDisplay(expected: ir.Type, got_disp: []const u8, got: ir.Type) bool {
    const exp = ir.peelDefined(expected);
    if (exp == .union_) {
        for (exp.union_) |arm| {
            if (literalTypeAcceptsDisplay(arm, got_disp, got)) return true;
        }
        return false;
    }
    if (exp == .str_lit and types.isStringyType(got_disp)) return true;
    if (exp == .int_lit and (isUntypedIntDisplay(got_disp) or got == .i64 or ir.isInteger(got))) return true;
    if (exp == .bool_lit and (got == .u1 or std.mem.eql(u8, got_disp, "bool") or std.mem.eql(u8, got_disp, "boolean") or std.mem.eql(u8, got_disp, "u1"))) return true;
    return false;
}

/// `int` / `number` as spelled by literal inference (before alias normalize to `i64`).
fn isUntypedIntDisplay(s: []const u8) bool {
    if (std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "number")) return true;
    if (arrayElemSuffix(s)) |elem| return isUntypedIntDisplay(elem);
    return false;
}

fn untypedIntCoerces(g: ir.Type, e: ir.Type) bool {
    if (ir.isInteger(e) and g == .i64) return true;
    if (g == .array and e == .array) {
        if (!untypedIntCoerces(g.array.elem.*, e.array.elem.*)) return false;
        if (e.array.length == null) return true;
        if (g.array.length == null) return false;
        return g.array.length.? == e.array.length.?;
    }
    return false;
}

fn arrayElemSuffix(display: []const u8) ?[]const u8 {
    if (display.len < 2 or display[0] != '[') return null;
    if (display[1] == ']') return display[2..];
    var i: usize = 1;
    while (i < display.len and display[i] >= '0' and display[i] <= '9') : (i += 1) {}
    if (i < display.len and display[i] == ']') return display[i + 1 ..];
    return null;
}

fn inferDeclType(state: *CompilerState, value: *ast.Node) ?[]const u8 {
    return switch (value.*) {
        .struct_init => |s| types.resolveStructName(state, s.type_expr),
        .array_literal => |a| blk: {
            if (a.elements.len == 0) {
                const s = std.fmt.allocPrint(state.allocator, "[0]unknown", .{}) catch break :blk null;
                state.owned.append(state.allocator, s) catch {};
                break :blk s;
            }
            const elem = inferDeclType(state, a.elements[0]) orelse "unknown";
            const s = std.fmt.allocPrint(state.allocator, "[{d}]{s}", .{ a.elements.len, elem }) catch break :blk null;
            state.owned.append(state.allocator, s) catch {};
            break :blk s;
        },
        .literal => |lit| switch (lit.literal_type) {
            .string => blk: {
                const s = std.fmt.allocPrint(state.allocator, "[{d}]byte", .{lit.value.len}) catch break :blk null;
                state.owned.append(state.allocator, s) catch {};
                break :blk s;
            },
            .boolean => "u1",
            .null => "null",
            .number, .hex, .octal, .binary => if (std.mem.indexOfScalar(u8, lit.value, '.') != null) "float" else "int",
        },
        .call => types.resolveType(state, value),
        .try_expr => types.resolveType(state, value),
        .index => types.resolveType(state, value),
        .unary => |u| inferDeclType(state, u.arg),
        .binary => |b| blk: {
            const lt = inferDeclType(state, b.left);
            const rt = inferDeclType(state, b.right);
            if (lt != null and rt != null) {
                if (std.mem.eql(u8, lt.?, "float") or std.mem.eql(u8, rt.?, "float")) break :blk "float";
                if (std.mem.eql(u8, lt.?, "int") and std.mem.eql(u8, rt.?, "int")) break :blk "int";
            }
            break :blk types.resolveType(state, value);
        },
        .primary => types.resolveType(state, value),
        .member => types.resolveType(state, value),
        else => null,
    };
}

fn checkLocalDup(state: *CompilerState, name: []const u8) !void {
    var i = state.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = state.locals.items[i];
        if (local.depth < state.scope_depth) break;
        if (std.mem.eql(u8, local.name, name)) {
            return @import("../../errors/compile.zig").compileFailFmt(state, "Variable '{s}' already declared in this scope", .{name});
        }
    }
}

pub fn compileExtern(state: *CompilerState, ext: *const ast.Extern) !void {
    try state.native_globals.put(ext.name, {});
}

pub fn compileStruct(state: *CompilerState, s: *const ast.StructDecl) !void {
    const layout = @import("../layout.zig");
    var type_map = std.StringHashMap([]const u8).init(state.allocator);
    var field_list: std.ArrayList(layout.FieldSpec) = .empty;
    defer field_list.deinit(state.allocator);

    for (s.fields) |field| {
        var disp: []const u8 = "int";
        if (field.type_annotation) |ta| {
            disp = (try from_ast.typeAstToDisplay(ta, state)) orelse "unknown";
        }
        try type_map.put(field.name, disp);
        try field_list.append(state.allocator, .{ .name = field.name, .type_name = disp });
    }
    const laid = try layout.layoutFields(state.allocator, field_list.items);
    if (state.structs.fetchRemove(s.name)) |kv| {
        var old = kv.value;
        old.offsets.deinit();
        old.types.deinit();
    }
    try state.structs.put(s.name, .{
        .name = s.name,
        .size = laid.size,
        .offsets = laid.offsets,
        .types = type_map,
    });

    // Qualify method names to Struct::method for dispatch
    for (s.methods) |m| {
        if (m.* != .function_decl) continue;
        if (std.mem.indexOf(u8, m.function_decl.name, "::") != null) continue;
        const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ s.name, m.function_decl.name });
        try state.owned.append(state.allocator, q);
        // Update pending function registry key
        if (state.functions.fetchRemove(m.function_decl.name)) |kv| {
            var def = kv.value;
            m.function_decl.name = q;
            def.node = m;
            try state.functions.put(q, def);
        } else {
            m.function_decl.name = q;
        }
    }
}

pub fn compileEnum(state: *CompilerState, e: *const ast.EnumDecl) !void {
    var variants = std.StringHashMap(i32).init(state.allocator);
    for (e.variants, 0..) |name, i| {
        if (variants.contains(name)) {
            variants.deinit();
            return @import("../../errors/compile.zig").compileFailFmt(state, "Duplicate enum variant '{s}' in '{s}'", .{ name, e.name });
        }
        try variants.put(name, @intCast(i));
    }
    if (state.enums.fetchRemove(e.name)) |kv| {
        var old = kv.value;
        old.variants.deinit();
    }
    try state.enums.put(e.name, .{
        .name = e.name,
        .variants = variants,
    });
}

pub fn compileErrorDecl(state: *CompilerState, e: *const ast.ErrorDecl) !void {
    if (state.structs.contains(e.name) or state.enums.contains(e.name) or state.typedefs.contains(e.name)) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Type name '{s}' already used", .{e.name});
    }
    var variants = std.StringHashMap([]const u8).init(state.allocator);
    for (e.variants) |name| {
        if (variants.contains(name)) {
            variants.deinit();
            return @import("../../errors/compile.zig").compileFailFmt(state, "Duplicate error member '{s}' in '{s}'", .{ name, e.name });
        }
        try variants.put(name, e.name);
    }
    if (state.error_sets.fetchRemove(e.name)) |kv| {
        var old = kv.value;
        old.variants.deinit();
    }
    try state.error_sets.put(e.name, .{
        .name = e.name,
        .variants = variants,
    });
}

pub fn compileTypeDecl(state: *CompilerState, td: *const ast.TypeDecl) !void {
    if (state.structs.contains(td.name) or state.enums.contains(td.name) or state.error_sets.contains(td.name)) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Type name '{s}' already used by a struct, enum, or error set", .{td.name});
    }
    if (state.typedefs.contains(td.name)) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Duplicate type '{s}'", .{td.name});
    }
    if (ir.isBuiltinTypeName(td.name)) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Cannot redefine builtin type '{s}'", .{td.name});
    }
    const disp = (try from_ast.typeAstToDisplay(td.type_expr, state)) orelse {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Invalid type expression for '{s}'", .{td.name});
    };
    try state.typedefs.put(td.name, .{
        .name = td.name,
        .underlying = disp,
        .distinct = td.distinct,
    });
    // Shape / merged-intersection RHS: layout under typedef name and display key.
    if (disp.len > 0 and disp[0] == '{') {
        if (td.type_expr.* == .shape_type) {
            try registerShapeLayout(state, td.name, &td.type_expr.shape_type);
            if (!std.mem.eql(u8, td.name, disp)) {
                try registerShapeLayout(state, disp, &td.type_expr.shape_type);
            }
        } else {
            try from_ast.ensureShapeLayoutFromDisplay(state, disp);
            if (!std.mem.eql(u8, td.name, disp)) {
                try from_ast.ensureShapeLayoutFromDisplayAs(state, disp, td.name);
            }
        }
    }
}

fn registerShapeLayout(state: *CompilerState, key: []const u8, shape: *const ast.ShapeType) !void {
    if (state.structs.contains(key)) return;
    const layout = @import("../layout.zig");
    var type_map = std.StringHashMap([]const u8).init(state.allocator);
    var field_list: std.ArrayList(layout.FieldSpec) = .empty;
    defer field_list.deinit(state.allocator);

    for (shape.fields) |field| {
        var field_disp: []const u8 = "int";
        if (field.type_annotation) |ta| {
            field_disp = (try from_ast.typeAstToDisplay(ta, state)) orelse "unknown";
        }
        try type_map.put(field.name, field_disp);
        try field_list.append(state.allocator, .{ .name = field.name, .type_name = field_disp });
    }
    const laid = try layout.layoutFields(state.allocator, field_list.items);
    try state.structs.put(key, .{
        .name = key,
        .size = laid.size,
        .offsets = laid.offsets,
        .types = type_map,
    });
}

fn widthCastKind(node: *ast.Node) ?u8 {
    if (node.* != .primary or node.primary.kind != .identifier) return null;
    const widths = @import("../widths.zig");
    if (widths.fromName(node.primary.name)) |w| return @intFromEnum(w);
    return null;
}
