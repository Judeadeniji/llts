const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const CompilerState = state_mod.CompilerState;

const typecheck_root = @import("typecheck/root.zig");
const ir = @import("typecheck/ir.zig");
const from_ast = @import("typecheck/from_ast.zig");

const emit = @import("emit.zig");
const expr = @import("expr/root.zig");
const aggregate = @import("expr/aggregate.zig");
const path = @import("expr/path.zig");
const modules = @import("modules.zig");
const compile_errors = @import("../errors/compile.zig");

pub const Intrinsic = enum {
    import,
    typeOf,
    isError,
    sizeOf,
    as,
    new,
};

pub fn match(callee: []const u8) ?Intrinsic {
    if (std.mem.eql(u8, callee, "@import")) return .import;
    if (std.mem.eql(u8, callee, "@typeOf")) return .typeOf;
    if (std.mem.eql(u8, callee, "@isError")) return .isError;
    if (std.mem.eql(u8, callee, "@sizeOf")) return .sizeOf;
    if (std.mem.eql(u8, callee, "@as")) return .as;
    if (std.mem.eql(u8, callee, "@new")) return .new;
    return null;
}

pub const Arity = union(enum) {
    exact: u8,
    range: struct { min: u8, max: u8 },
};

pub fn arity(intr: Intrinsic) Arity {
    return switch (intr) {
        .import => .{ .exact = 1 },
        .typeOf => .{ .exact = 1 },
        .isError => .{ .exact = 1 },
        .sizeOf => .{ .exact = 1 },
        .as => .{ .exact = 2 },
        .new => .{ .range = .{ .min = 2, .max = 3 } },
    };
}

pub fn checkArity(state: *CompilerState, intr: Intrinsic, name: []const u8, got: usize) !void {
    const a = arity(intr);
    switch (a) {
        .exact => |e| {
            if (got != e) {
                return compile_errors.compileFailFmt(state, "{s} expects exactly {d} argument(s)", .{ name, e });
            }
        },
        .range => |r| {
            if (got < r.min or got > r.max) {
                return compile_errors.compileFailFmt(state, "{s} expects between {d} and {d} arguments", .{ name, r.min, r.max });
            }
        },
    }
}

pub fn typecheck(state: *CompilerState, env: *typecheck_root.Env, ta: ir.TypeAlloc, intr: Intrinsic, call_node: *ast.Node, c: *const ast.Call) !ir.Type {
    const name = c.callee.primary.name;
    try checkArity(state, intr, name, c.args.len);

    switch (intr) {
        .import => {
            const arg = c.args[0];
            const arg_type = try typecheck_root.inferExpr(state, env, ta, arg);
            try typecheck_root.requireAssign(state, arg_type, ir.TString, "@import path");
            if (arg.* != .literal or arg.literal.literal_type != .string) return ir.TUnknown;
            const from = if (state.diag_path.len > 0) state.diag_path else state.chunk.file;
            const key = modules.resolveImportKey(state, from, arg.literal.value) catch return ir.TUnknown;
            const mod_val = try std.fmt.allocPrint(state.allocator, "module:{s}", .{key});
            try state.owned.append(state.allocator, mod_val);
            return .{ .struct_ = mod_val };
        },
        .isError => {
            _ = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            return ir.TBool;
        },
        .typeOf => {
            const arg_type = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            const disp = try typecheck_root.ownDisplay(state, arg_type);
            try state.type_of_results.put(call_node, disp);
            return ir.TString;
        },
        .sizeOf => {
            _ = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            return ir.TInt;
        },
        .as => {
            return try typecheckCast(state, env, ta, c.args[0], c.args[1]);
        },
        .new => {
            _ = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            const v = c.args[1];
            if (c.args.len == 3) _ = try typecheck_root.inferExpr(state, env, ta, c.args[2]);
            const base: ir.Type = switch (v.*) {
                .array_type, .union_type, .pointer_type, .func_type => try from_ast.typeFromAst(v, state, ta),
                .primary => |p| blk: {
                    if (p.kind == .identifier) {
                        if (std.mem.eql(u8, p.name, "string") or std.mem.eql(u8, p.name, "[]byte")) {
                            break :blk ir.TString;
                        }
                        if (state.structs.contains(p.name) or state.enums.contains(p.name) or state.typedefs.contains(p.name)) {
                            break :blk try from_ast.typeFromAst(v, state, ta);
                        }
                        const named = ir.namedType(p.name);
                        if (named != .struct_) break :blk named;
                    }
                    break :blk try typecheck_root.inferExpr(state, env, ta, v);
                },
                else => try typecheck_root.inferExpr(state, env, ta, v),
            };
            // Heap-allocated structs are pointers (handles into packed bytes).
            if (base == .struct_) return try ta.ptrType(base);
            if (base == .ptr) return base;
            return base;
        },
    }
}

pub fn compile(state: *CompilerState, intr: Intrinsic, node: *ast.Node, c: *const ast.Call) !void {
    const name = c.callee.primary.name;
    // We assume arity was checked in typecheck, but we can assert or just check again.
    // In debug builds we could assert. For now let's just do it.
    try checkArity(state, intr, name, c.args.len);

    switch (intr) {
        .import => {
            // side-effect import or bound import; in Phase 1 this might not be called directly
            // since parser still splits @import, but for uniformity we add it.
            // Do nothing if it's just a call, or we could compile the arg.
            try expr.compileExpression(state, c.args[0]);
            try emit.emitOp(state, .OP_POP);
        },
        .isError => {
            try expr.compileExpression(state, c.args[0]);
            try emit.emitOp(state, .OP_IS_ERROR);
        },
        .typeOf => {
            const disp = state.type_of_results.get(node) orelse
                from_ast.resolveType(state, c.args[0]) orelse "unknown";
            try expr.compileExpression(state, c.args[0]);
            try emit.emitOp(state, .OP_POP);
            try emit.emitString(state, disp);
        },
        .sizeOf => {
            var static_type: ?[]const u8 = null;
            if (c.args[0].* == .primary and c.args[0].primary.kind == .identifier) {
                static_type = c.args[0].primary.name;
            } else if (c.args[0].* == .pointer_type or c.args[0].* == .array_type or c.args[0].* == .union_type or c.args[0].* == .func_type) {
                static_type = try from_ast.typeAstToDisplay(c.args[0], state);
            } else if (try path.tryResolveStaticPath(state, c.args[0])) |p| {
                static_type = p;
            }

            if (static_type) |st| {
                var is_type = false;
                var size: i32 = 0;
                const layout = @import("layout.zig");
                const widths = @import("widths.zig");
                if (st.len > 0 and (st[0] == '*' or st[0] == '?')) {
                    is_type = true;
                    size = layout.sizeOfTypeName(st);
                } else if (std.mem.startsWith(u8, st, "@func(")) {
                    is_type = true;
                    size = 8;
                } else if (widths.fromName(st)) |w| {
                    is_type = true;
                    size = w.size();
                } else if (std.mem.eql(u8, st, "null")) {
                    is_type = true;
                    size = 0;
                } else if (std.mem.eql(u8, st, "string") or std.mem.eql(u8, st, "[]byte")) {
                    is_type = true;
                    size = 8;
                } else if (state.structs.get(st)) |sd| {
                    is_type = true;
                    size = sd.size;
                } else if (state.enums.contains(st)) {
                    is_type = true;
                    size = 8;
                } else if (state.typedefs.contains(st)) {
                    is_type = true;
                    size = layout.sizeOfNamedType(state, st);
                }
                if (is_type) {
                    try emit.emitConstant(state, .{ .i64 = size });
                    return;
                }
            }
            
            if (from_ast.resolveType(state, c.args[0])) |type_name| {
                if (from_ast.lookupStruct(state, type_name)) |sd| {
                    try expr.compileExpression(state, c.args[0]);
                    try emit.emitOp(state, .OP_POP);
                    try emit.emitConstant(state, .{ .i64 = sd.size });
                    return;
                }
            }

            try expr.compileExpression(state, c.args[0]);
            try emit.emitOp(state, .OP_SIZEOF);
        },
        .as => {
            try compileCast(state, c.args[0], c.args[1]);
        },
        .new => {
            try aggregate.compileNew(state, c);
        },
    }
}

/// `Name(expr)` cast sugar when `Name` is a type and not a function/native.
/// Returns the type AST node (the callee) on match.
pub fn tryTypeCastCall(state: *CompilerState, c: *const ast.Call) !?*ast.Node {
    if (c.args.len != 1) return null;

    if (c.callee.* == .primary) {
        const name = c.callee.primary.name;
        if (name.len == 0 or name[0] == '@') return null;
        if (isCallableName(state, name)) return null;
        if (!isTypeName(state, name)) return null;
        return c.callee;
    }

    if (c.callee.* == .member) {
        // `Mod.Type(x)` / `Enum.Variant(x)` via static path only — not `obj.field(x)`.
        const resolved = (path.tryResolveStaticPath(state, c.callee) catch null) orelse return null;
        if (isCallableName(state, resolved)) return null;
        if (!isTypeName(state, resolved)) return null;
        return c.callee;
    }

    return null;
}

fn isCallableName(state: *CompilerState, name: []const u8) bool {
    if (state.functions.contains(name)) return true;
    if (state.chunk.functions.contains(name)) return true;
    if (state.native_globals.contains(name)) return true;
    return false;
}

fn isTypeName(state: *CompilerState, name: []const u8) bool {
    if (ir.isBuiltinTypeName(name)) return true;
    if (std.mem.eql(u8, name, "[]byte")) return true;
    if (state.typedefs.contains(name)) return true;
    if (state.structs.contains(name)) return true;
    if (state.enums.contains(name)) return true;
    // `Enum.Variant` singleton type
    if (std.mem.indexOf(u8, name, "::") == null) {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            if (dot > 0 and dot + 1 < name.len) {
                const ename = name[0..dot];
                const vname = name[dot + 1 ..];
                if (state.enums.get(ename)) |ed| {
                    if (ed.variants.contains(vname)) return true;
                }
            }
        }
    }
    return false;
}

/// Typecheck `T(x)` / `@as(T, x)` — returns the target type.
pub fn typecheckCast(state: *CompilerState, env: *typecheck_root.Env, ta: ir.TypeAlloc, type_node: *ast.Node, value: *ast.Node) !ir.Type {
    const target = try from_ast.typeFromAst(type_node, state, ta);
    const src = try typecheck_root.inferExpr(state, env, ta, value);
    try checkAsCast(state, src, target);
    return target;
}

/// Emit `T(x)` / `@as(T, x)`.
pub fn compileCast(state: *CompilerState, type_node: *ast.Node, value: *ast.Node) !void {
    if (try asCastKind(state, type_node)) |kind| {
        try expr.compileExpression(state, value);
        try emit.emitOp(state, .OP_AS);
        try emit.emitByte(state, kind);
    } else {
        try expr.compileExpression(state, value);
    }
}

/// Operand for `OP_AS`: `widths.Width` discriminant, or null when no runtime cast needed.
pub fn asCastKind(state: *CompilerState, type_node: *ast.Node) !?u8 {
    const widths = @import("widths.zig");
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };
    const target = try from_ast.typeFromAst(type_node, state, ta);
    const peeled = ir.peelDefined(target);
    if (ir.widthOf(peeled)) |w| return @intFromEnum(w);
    if (peeled == .enum_ or peeled == .enum_lit) return @intFromEnum(widths.Width.i64);
    // Same-layout nominal / string / struct / etc. — no OP_AS.
    return null;
}

pub fn checkAsCast(state: *CompilerState, src: ir.Type, target: ir.Type) !void {
    if (ir.involvesUnknown(src) or ir.involvesUnknown(target)) return;
    const su = ir.peelDefined(src);
    const tu = ir.peelDefined(target);
    // Numeric / enum casts (existing).
    const num_ok = (ir.isNumeric(su) or su == .enum_ or su == .enum_lit) and (ir.isNumeric(tu) or tu == .enum_ or tu == .enum_lit);
    if (num_ok) return;
    // Same underlying shape (UUID ↔ ID, Expr ↔ Literal|Add, etc.).
    if (ir.typeEquals(su, tu) or ir.isSubtype(su, tu) or ir.isSubtype(tu, su)) return;
    const ds = try typecheck_root.ownDisplay(state, src);
    const dt = try typecheck_root.ownDisplay(state, target);
    return compile_errors.compileFailFmt(state, "cannot cast to '{s}' from '{s}'", .{ dt, ds });
}
