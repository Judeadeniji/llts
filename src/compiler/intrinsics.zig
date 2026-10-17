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
const scope = @import("scope.zig");

const layout = @import("layout.zig");
const widths = @import("widths.zig");

pub const Intrinsic = enum {
    import,
    typeOf,
    isError,
    sizeOf,
    nameOf,
    as,
    new,
};

const intrinsics = std.StaticStringMap(Intrinsic).initComptime(.{
    .{ "@import", .import },
    .{ "@typeOf", .typeOf },
    .{ "@isError", .isError },
    .{ "@sizeOf", .sizeOf },
    .{ "@nameOf", .nameOf },
    .{ "@as", .as },
    .{ "@new", .new },
});

pub fn match(callee: []const u8) ?Intrinsic {
    return intrinsics.get(callee);
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
        .nameOf => .{ .exact = 1 },
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
            const arg = c.args[0];
            const denoted: ir.Type = if (isTypeValueNode(state, env, arg)) blk: {
                _ = try denotedType(state, env, ta, arg);
                break :blk ir.TType;
            } else blk: {
                const t = try typecheck_root.inferExpr(state, env, ta, arg);
                if (t == .unknown) try requireKnownIdentifier(state, env, arg);
                break :blk t;
            };
            try state.type_of_results.put(call_node, try typecheck_root.ownDisplay(state, denoted));
            try recordTypeValue(state, call_node, denoted);
            return ir.TType;
        },
        .sizeOf => {
            const arg = c.args[0];
            if (isTypeValueNode(state, env, arg)) {
                const t = try denotedType(state, env, ta, arg);
                const size = (try layout.sizeOfType(state, t)) orelse {
                    const d = try typecheck_root.ownDisplay(state, t);
                    return compile_errors.compileFailFmt(state, "@sizeOf: type '{s}' has no static size", .{d});
                };
                try state.size_of_results.put(call_node, size);
            } else {
                _ = try typecheck_root.inferExpr(state, env, ta, arg);
            }
            return ir.TInt;
        },
        .nameOf => {
            const arg_type = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            const peeled = ir.peelDefined(arg_type);
            const plan: state_mod.NameOfPlan = switch (peeled) {
                .enum_lit => |e| .{ .fold = e.variant },
                .enum_ => |ename| blk: {
                    // `@nameOf(Color)` — bare enum type used as argument: fold to its name.
                    // `@nameOf(someVar)` — runtime enum value: emit a dispatch table.
                    if (isBareName(c.args[0], ename)) break :blk .{ .decl_name = ename };
                    break :blk .{ .enum_type = ename };
                },
                .error_lit => |e| .{ .fold = e.variant },
                .error_set => |ename| blk: {
                    // `@nameOf(IoError)` — bare error set type: fold to its name.
                    // `@nameOf(err)` — runtime error value: emit OP_ERROR_NAME.
                    if (isBareName(c.args[0], ename)) break :blk .{ .decl_name = ename };
                    break :blk .error_code;
                },
                .error_ => .error_code,
                else => blk: {
                    // For any other type, try to extract a static declaration name
                    // from the argument AST node itself.
                    if (tryResolveNameOfDecl(state, c.args[0])) |decl_name| {
                        break :blk .{ .decl_name = decl_name };
                    }
                    const disp = try typecheck_root.ownDisplay(state, arg_type);
                    return compile_errors.compileFailFmt(state, "@nameOf expects an enum, error, or named declaration, got '{s}'", .{disp});
                },
            };
            try state.name_of_plans.put(call_node, plan);
            return ir.TString;
        },
        .as => {
            return try typecheckCast(state, env, ta, c.args[0], c.args[1]);
        },
        .new => {
            _ = try typecheck_root.inferExpr(state, env, ta, c.args[0]);
            const v = c.args[1];
            if (c.args.len == 3) _ = try typecheck_root.inferExpr(state, env, ta, c.args[2]);
            const base: ir.Type = switch (v.*) {
                .array_type, .union_type, .intersection_type, .pointer_type, .func_type, .tuple_type, .shape_type => blk: {
                    try resolveTypeExprs(state, env, ta, v);
                    break :blk try from_ast.typeFromAst(v, state, ta);
                },
                .call => blk: {
                    if (!from_ast.isTypeCall(state, v)) break :blk try typecheck_root.inferExpr(state, env, ta, v);
                    try resolveTypeExprs(state, env, ta, v);
                    break :blk try from_ast.typeFromAst(v, state, ta);
                },
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
                .member => blk: {
                    // Qualified struct type (`mod.Type`).
                    if (from_ast.resolveStructName(state, v)) |sn| {
                        if (state.structs.contains(sn) or state.typedefs.contains(sn)) {
                            break :blk ir.namedType(sn);
                        }
                    }
                    break :blk try typecheck_root.inferExpr(state, env, ta, v);
                },
                else => try typecheck_root.inferExpr(state, env, ta, v),
            };
            // Arena/heap allocation always yields a pointer handle (`*T`), matching
            // `@new(a, Point)` → `*Point`. Arrays / `[]T` / `[]byte` / shapes too.
            if (base == .struct_ or base == .defined or base == .array or base == .tuple or base == .shape)
                return try ta.ptrType(base);
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
            // Purely static: the operand is never evaluated.
            try emit.emitString(state, state.type_of_results.get(node) orelse "unknown");
        },
        .sizeOf => {
            if (state.size_of_results.get(node)) |size| {
                try emit.emitConstant(state, .{ .i64 = size });
                return;
            }
            if (try staticTypeArgSize(state, c.args[0])) |size| {
                try emit.emitConstant(state, .{ .i64 = size });
                return;
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
        .nameOf => {
            const plan = state.name_of_plans.get(node) orelse {
                return compile_errors.compileFailFmt(state, "Internal error: @nameOf missing type plan", .{});
            };
            switch (plan) {
                .fold => |spelling| {
                    try expr.compileExpression(state, c.args[0]);
                    try emit.emitOp(state, .OP_POP);
                    try emit.emitString(state, spelling);
                },
                .enum_type => |ename| try compileNameOfEnum(state, ename, c.args[0]),
                .error_code => {
                    try expr.compileExpression(state, c.args[0]);
                    try emit.emitOp(state, .OP_ERROR_NAME);
                },
                .decl_name => |spelling| {
                    // Pure type names (enum, struct, typedef, error_set) have no runtime
                    // representation — skip evaluation and emit the name directly.
                    // For actual runtime declarations (vars, functions) evaluate-and-pop
                    // to preserve any side-effects in the expression.
                    const arg = c.args[0];
                    const is_type_name = arg.* == .primary and
                        arg.primary.kind == .identifier and
                        (state.enums.contains(arg.primary.name) or
                            state.structs.contains(arg.primary.name) or
                            state.typedefs.contains(arg.primary.name) or
                            state.error_sets.contains(arg.primary.name));
                    if (!is_type_name) {
                        try expr.compileExpression(state, arg);
                        try emit.emitOp(state, .OP_POP);
                    }
                    try emit.emitString(state, spelling);
                },
            }
        },
        .as => {
            try compileCast(state, c.args[0], c.args[1]);
        },
        .new => {
            try aggregate.compileNew(state, c);
        },
    }
}

/// Emit-time `@sizeOf` for a bare type argument the typechecker did not visit.
fn staticTypeArgSize(state: *CompilerState, node: *ast.Node) !?i32 {
    const is_type = switch (node.*) {
        .pointer_type, .array_type, .union_type, .intersection_type, .func_type, .tuple_type, .shape_type => true,
        .primary => |p| p.kind == .identifier and scope.resolveLocal(state, p.name) == -1 and
            !state.global_vars.contains(p.name) and isTypeName(state, p.name),
        .member => (try path.tryResolveStaticPath(state, node)) != null and !isEnumOrErrorMember(state, node),
        else => false,
    };
    if (!is_type) return null;
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };
    const t = from_ast.typeFromAst(node, state, ta) catch return null;
    return try layout.sizeOfType(state, t);
}

/// `Enum.Variant` / `ErrorSet.Member` in expression position is a value, not a type.
fn isEnumOrErrorMember(state: *CompilerState, node: *ast.Node) bool {
    if (node.* != .member or node.member.property.* != .primary) return false;
    const prop = node.member.property.primary.name;
    if (from_ast.resolveEnumName(state, node.member.object)) |ename| {
        if (state.enums.get(ename)) |ed| return ed.variants.contains(prop);
    }
    if (from_ast.resolveErrorSetName(state, node.member.object)) |esname| {
        if (state.error_sets.get(esname)) |ed| return ed.variants.contains(prop);
    }
    return false;
}

/// A node used as a `type` value: a type-returning call or a bare type expression.
pub fn isTypeValueNode(state: *CompilerState, env: *typecheck_root.Env, node: *ast.Node) bool {
    return from_ast.isTypeCall(state, node) or isBareTypeNode(state, env, node);
}

/// Record the type a type-valued node denotes (read back by `typeFromAst`).
pub fn recordTypeValue(state: *CompilerState, node: *ast.Node, t: ir.Type) !void {
    try state.type_call_results.put(node, try typecheck_root.ownDisplayQualified(state, t));
}

/// The type denoted by a type-valued node (see `isTypeValueNode`).
pub fn denotedType(state: *CompilerState, env: *typecheck_root.Env, ta: ir.TypeAlloc, node: *ast.Node) !ir.Type {
    if (from_ast.isTypeCall(state, node)) {
        _ = try typecheck_root.inferExpr(state, env, ta, node);
        const disp = state.type_call_results.get(node) orelse return ir.TUnknown;
        return try from_ast.parseDisplayType(state, ta, disp, null);
    }
    try resolveTypeExprs(state, env, ta, node);
    const t = try from_ast.typeFromAst(node, state, ta);
    try recordTypeValue(state, node, t);
    return t;
}

/// Resolve every call inside a type AST (`$x: ?@typeOf(y)`) in `env`. Each call
/// must produce a `type`; its denoted type is recorded for `typeFromAst`.
pub fn resolveTypeExprs(state: *CompilerState, env: *typecheck_root.Env, ta: ir.TypeAlloc, node: ?*ast.Node) !void {
    const n = node orelse return;
    switch (n.*) {
        .call => {
            const t = try typecheck_root.inferExpr(state, env, ta, n);
            if (t != .type_) {
                const d = try typecheck_root.ownDisplay(state, t);
                return compile_errors.compileFailFmt(state, "Expected a type, found a value of type '{s}'", .{d});
            }
        },
        .array_type => |a| try resolveTypeExprs(state, env, ta, a.elem),
        .tuple_type => |t| for (t.elems) |e| try resolveTypeExprs(state, env, ta, e),
        .pointer_type => |p| try resolveTypeExprs(state, env, ta, p.elem),
        .func_type => |f| {
            for (f.params) |p| try resolveTypeExprs(state, env, ta, p);
            try resolveTypeExprs(state, env, ta, f.return_type);
        },
        .shape_type => |s| for (s.fields) |f| try resolveTypeExprs(state, env, ta, f.type_annotation),
        .union_type => |u| {
            try resolveTypeExprs(state, env, ta, u.left);
            try resolveTypeExprs(state, env, ta, u.right);
        },
        .intersection_type => |ix| {
            try resolveTypeExprs(state, env, ta, ix.left);
            try resolveTypeExprs(state, env, ta, ix.right);
        },
        .binary => |b| {
            try resolveTypeExprs(state, env, ta, b.left);
            try resolveTypeExprs(state, env, ta, b.right);
        },
        else => {},
    }
}

/// `@typeOf(name)` never evaluates its operand, so an undefined bare name must be
/// rejected here rather than by codegen.
fn requireKnownIdentifier(state: *CompilerState, env: *typecheck_root.Env, node: *ast.Node) !void {
    if (node.* != .primary or node.primary.kind != .identifier) return;
    const name = node.primary.name;
    if (env.lookup(name) != null) return;
    if (state.global_vars.contains(name) or state.global_consts.contains(name) or
        state.global_types.contains(name) or state.functions.contains(name) or
        state.native_globals.contains(name)) return;
    return compile_errors.compileFailFmt(state, "Unknown identifier '{s}'", .{name});
}

fn isBareTypeNode(state: *CompilerState, env: *typecheck_root.Env, node: *ast.Node) bool {
    switch (node.*) {
        .pointer_type, .array_type, .union_type, .intersection_type, .func_type, .tuple_type, .shape_type => return true,
        .primary => |p| {
            if (p.kind != .identifier) return false;
            const name = p.name;
            if (env.lookup(name) != null) return false;
            if (state.global_vars.contains(name)) return false;
            if (state.global_consts.contains(name)) return false;
            if (state.functions.contains(name)) return false;
            if (state.native_globals.contains(name)) return false;

            if (widths.fromName(name) != null) return true;
            if (std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "[]byte") or
                std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "error")) return true;
            if (state.structs.contains(name) or state.enums.contains(name) or
                state.typedefs.contains(name) or state.error_sets.contains(name)) return true;
            return false;
        },
        .member => |m| {
            if (m.object.* == .primary and env.lookup(m.object.primary.name) != null) return false;
            if (m.object.* == .primary and (state.global_vars.contains(m.object.primary.name) or state.global_consts.contains(m.object.primary.name))) return false;
            if (isEnumOrErrorMember(state, node)) return false;
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const ta = ir.TypeAlloc{ .allocator = arena.allocator() };
            const t = from_ast.typeFromAst(node, state, ta) catch return false;
            return t != .unknown;
        },
        .binary => |b| {
            if (std.mem.eql(u8, b.operator, "|") or std.mem.eql(u8, b.operator, "&")) {
                return isBareTypeNode(state, env, b.left) and isBareTypeNode(state, env, b.right);
            }
            return false;
        },
        else => return false,
    }
}

/// Returns true when `node` is a bare primary identifier whose text equals `name`.
/// Used to distinguish `@nameOf(Direction)` (the *type* — fold) from
/// `@nameOf(dir)` (a *variable* of enum type — runtime dispatch).
fn isBareName(node: *ast.Node, name: []const u8) bool {
    return node.* == .primary and
        node.primary.kind == .identifier and
        std.mem.eql(u8, node.primary.name, name);
}

/// Try to extract a static declaration name from an AST node for `@nameOf`.
///
/// Returns the *spelled* name (as declared in source) when the argument is:
///   - A local variable / parameter identifier
///   - A global variable, constant, or function identifier
///   - A struct, enum, error-set, or typedef identifier used as a value
///   - An enum variant accessed as `Enum.Variant` (returns `"Variant"`)
///   - A module-qualified name `mod.thing` (returns `"thing"`)
///
/// Returns `null` when the argument has no static declaration identity
/// (e.g. a numeric literal, arbitrary sub-expression, etc.).
fn tryResolveNameOfDecl(state: *CompilerState, node: *ast.Node) ?[]const u8 {
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) return null;
            const name = p.name;
            // Local variable or parameter.
            if (scope.resolveLocal(state, name) != -1) return name;
            // Global variable, constant, or function.
            if (state.global_vars.contains(name)) return name;
            if (state.global_consts.contains(name)) return name;
            if (state.functions.contains(name)) return name;
            if (state.native_globals.contains(name)) return name;
            // Type declarations used as expressions.
            if (state.structs.contains(name)) return name;
            if (state.enums.contains(name)) return name;
            if (state.error_sets.contains(name)) return name;
            if (state.typedefs.contains(name)) return name;
            return null;
        },
        .member => |m| {
            if (m.property.* != .primary) return null;
            const prop = m.property.primary.name;
            // `Enum.Variant` — return the variant spelling.
            if (m.object.* == .primary) {
                const obj_name = m.object.primary.name;
                if (state.enums.get(obj_name)) |ed| {
                    if (ed.variants.contains(prop)) return prop;
                }
                // `ErrorSet.Member` — return the member spelling.
                if (state.error_sets.get(obj_name)) |esd| {
                    if (esd.variants.contains(prop)) return prop;
                }
            }
            // Module-qualified `mod.thing` — return the last segment.
            if (path.tryResolveStaticPath(state, m.object) catch null) |obj_path| {
                _ = obj_path;
                return prop;
            }
            return null;
        },
        else => return null,
    }
}

fn compileNameOfEnum(state: *CompilerState, ename: []const u8, arg: *ast.Node) !void {
    const ed = state.enums.get(ename) orelse {
        return compile_errors.compileFailFmt(state, "@nameOf: unknown enum '{s}'", .{ename});
    };

    const Entry = struct { name: []const u8, val: i32 };
    var variants: std.ArrayList(Entry) = .empty;
    defer variants.deinit(state.allocator);
    var it = ed.variants.iterator();
    while (it.next()) |e| {
        try variants.append(state.allocator, .{ .name = e.key_ptr.*, .val = e.value_ptr.* });
    }
    std.mem.sort(Entry, variants.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.val < b.val;
        }
    }.less);

    try expr.compileExpression(state, arg);

    var end_jumps: std.ArrayList(usize) = .empty;
    defer end_jumps.deinit(state.allocator);

    for (variants.items) |item| {
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .i64 = item.val });
        try emit.emitOp(state, .OP_EQUAL);
        const miss = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
        try emit.emitOp(state, .OP_POP);
        try emit.emitOp(state, .OP_POP);
        try emit.emitString(state, item.name);
        const done = try emit.emitJump(state, .OP_JUMP);
        try end_jumps.append(state.allocator, done);
        emit.patchJump(state, miss);
        try emit.emitOp(state, .OP_POP);
    }
    try emit.emitOp(state, .OP_POP);
    try emit.emitString(state, "");
    for (end_jumps.items) |j| emit.patchJump(state, j);
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
    try resolveTypeExprs(state, env, ta, type_node);
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
    return compile_errors.compileFailFmt(state, "Cannot cast to '{s}' from '{s}'", .{ dt, ds });
}
