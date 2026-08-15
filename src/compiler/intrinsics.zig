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
            const target = try from_ast.typeFromAst(c.args[0], state, ta);
            const src = try typecheck_root.inferExpr(state, env, ta, c.args[1]);
            try checkAsCast(state, src, target);
            return target;
        },
        .new => {
            _ = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            const v = c.args[1];
            if (c.args.len == 3) _ = try typecheck_root.inferExpr(state, env, ta, c.args[2]);
            const base: ir.Type = switch (v.*) {
                .array_type, .union_type, .pointer_type => try from_ast.typeFromAst(v, state, ta),
                .primary => |p| blk: {
                    if (p.kind == .identifier) {
                        if (std.mem.eql(u8, p.name, "string") or std.mem.eql(u8, p.name, "[]byte")) {
                            break :blk ir.TString;
                        }
                        if (state.structs.contains(p.name) or state.enums.contains(p.name)) {
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
            } else if (c.args[0].* == .pointer_type or c.args[0].* == .array_type or c.args[0].* == .union_type) {
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
            const kind = try asCastKind(state, c.args[0]);
            try expr.compileExpression(state, c.args[1]);
            try emit.emitOp(state, .OP_AS);
            try emit.emitByte(state, kind);
        },
        .new => {
            try aggregate.compileNew(state, c);
        },
    }
}

/// Operand for `OP_AS`: `widths.Width` discriminant.
fn asCastKind(state: *CompilerState, type_node: *ast.Node) !u8 {
    const widths = @import("widths.zig");
    if (type_node.* == .primary and type_node.primary.kind == .identifier) {
        const n = type_node.primary.name;
        if (widths.fromName(n)) |w| return @intFromEnum(w);
        return compile_errors.compileFailFmt(state, "@as target must be a numeric width (got '{s}')", .{n});
    }
    return compile_errors.compileFailFmt(state, "@as target must be a type name", .{});
}

fn checkAsCast(state: *CompilerState, src: ir.Type, target: ir.Type) !void {
    if (ir.involvesUnknown(src) or ir.involvesUnknown(target)) return;
    const ok = (ir.isNumeric(src) or src == .enum_ or src == .enum_lit) and (ir.isNumeric(target) or target == .enum_ or target == .enum_lit);
    if (!ok) {
        const ds = try typecheck_root.ownDisplay(state, src);
        const dt = try typecheck_root.ownDisplay(state, target);
        return compile_errors.compileFailFmt(state, "cannot @as({s}, …) from '{s}'", .{ dt, ds });
    }
}
