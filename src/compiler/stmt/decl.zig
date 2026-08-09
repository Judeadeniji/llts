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
    if (decl.value.* == .import) return;

    if (decl.is_const) {
        var cenv = try const_expr.createConstEnv(state);
        defer cenv.deinit();
        // Include locals that are const in current scopes
        for (state.locals.items) |local| {
            if (local.is_const) try cenv.const_names.put(local.name, {});
        }
        if (!const_expr.isConstantExpr(state, &cenv, decl.value)) {
            std.debug.print(
                "CompileError: '{s}' is @const but initializer is not a compile-time constant\n",
                .{decl.name},
            );
            return error.CompileError;
        }
    }

    try expr.compileExpression(state, decl.value);

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
                if (!typesAssignable(got, expected)) {
                    std.debug.print(
                        "CompileError: declaration of '{s}': type '{s}' is not assignable to '{s}'\n",
                        .{ decl.name, got, expected },
                    );
                    return error.CompileError;
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

    const is_module_export = std.mem.indexOf(u8, decl.name, "::") != null;
    if (state.scope_depth > 0 and !is_module_export) {
        try checkLocalDup(state, decl.name);
        try state.locals.append(state.allocator, .{
            .name = decl.name,
            .depth = state.scope_depth,
            .type_name = type_name,
            .is_const = decl.is_const,
        });
        if (decl.is_const) {
            try emit.emitOp(state, .OP_MARK_CONST);
            try emit.emitByte(state, @intCast(state.locals.items.len - 1));
        }
    } else {
        if (state.global_vars.contains(decl.name)) {
            std.debug.print("CompileError: Variable '{s}' already declared in this scope\n", .{decl.name});
            return error.CompileError;
        }
        try state.global_vars.put(decl.name, {});
        if (type_name) |tn| try state.global_types.put(decl.name, tn);
        if (decl.is_const) try state.global_consts.put(decl.name, {});
        try emit.emitNameGet(state, .OP_SET_GLOBAL, decl.name);
        try emit.emitOp(state, .OP_POP);
    }
}

fn typesAssignable(got: []const u8, expected: []const u8) bool {
    if (std.mem.eql(u8, got, expected)) return true;
    if (std.mem.eql(u8, expected, "unknown") or std.mem.eql(u8, got, "unknown")) return true;
    if (std.mem.indexOf(u8, got, "unknown") != null or std.mem.indexOf(u8, expected, "unknown") != null) return true;
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
    // [N]T <: []T when element types match
    if (std.mem.startsWith(u8, got, "[") and std.mem.startsWith(u8, expected, "[]")) {
        // Compare element suffixes
        const got_elem = arrayElemSuffix(got) orelse return false;
        const exp_elem = expected[2..];
        return std.mem.eql(u8, got_elem, exp_elem);
    }
    // Same element, different size → not assignable
    if (std.mem.startsWith(u8, got, "[") and std.mem.startsWith(u8, expected, "[")) {
        const ge = arrayElemSuffix(got) orelse return false;
        const ee = arrayElemSuffix(expected) orelse return false;
        if (!std.mem.eql(u8, ge, ee)) return false;
        // lengths differ
        return false;
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
        .struct_init => |s| blk: {
            if (std.mem.indexOfScalar(u8, s.name, '.') != null) {
                break :blk @import("../expr/path.zig").resolveModuleType(state, s.name) catch s.name;
            }
            break :blk s.name;
        },
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
            .boolean => "bool",
            .@"null" => "null",
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
            std.debug.print("CompileError: Variable '{s}' already declared in this scope\n", .{name});
            return error.CompileError;
        }
    }
}

pub fn compileExtern(state: *CompilerState, ext: *const ast.Extern) !void {
    try state.native_globals.put(ext.name, {});
}

pub fn compileStruct(state: *CompilerState, s: *const ast.StructDecl) !void {
    var offsets = std.StringHashMap(i32).init(state.allocator);
    var type_map = std.StringHashMap([]const u8).init(state.allocator);
    var size: i32 = 0;
    for (s.fields) |field| {
        try offsets.put(field.name, size);
        size += 1;
        if (field.type_annotation) |ta| {
            const disp = (try from_ast.typeAstToDisplay(ta, state)) orelse "unknown";
            try type_map.put(field.name, disp);
        }
    }
    if (state.structs.fetchRemove(s.name)) |kv| {
        var old = kv.value;
        old.offsets.deinit();
        old.types.deinit();
    }
    try state.structs.put(s.name, .{
        .name = s.name,
        .size = size,
        .offsets = offsets,
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
