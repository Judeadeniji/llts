const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const from_ast = @import("from_ast.zig");
const ir = @import("ir.zig");
const path = @import("../expr/path.zig");

pub const typeAstToDisplay = from_ast.typeAstToDisplay;

pub const TypecheckError = error{ OutOfMemory, CompileError, Overflow, InvalidCharacter };

const Env = struct {
    locals: std.ArrayList(std.StringHashMap(ir.Type)),
    globals: std.StringHashMap(ir.Type),
    expected_return: ?ir.Type = null,
    annotated_return: ?ir.Type = null,
    const_names: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Env {
        return .{
            .locals = .empty,
            .globals = std.StringHashMap(ir.Type).init(allocator),
            .const_names = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Env) void {
        for (self.locals.items) |*m| m.deinit();
        self.locals.deinit(self.allocator);
        self.globals.deinit();
        self.const_names.deinit();
    }

    fn pushScope(self: *Env) !void {
        try self.locals.append(self.allocator, std.StringHashMap(ir.Type).init(self.allocator));
    }

    fn popScope(self: *Env) void {
        if (self.locals.items.len == 0) return;
        var m = self.locals.pop().?;
        m.deinit();
    }

    fn define(self: *Env, name: []const u8, t: ir.Type) !void {
        if (self.locals.items.len > 0) {
            try self.locals.items[self.locals.items.len - 1].put(name, t);
        } else {
            try self.globals.put(name, t);
        }
    }

    fn lookup(self: *Env, name: []const u8) ?ir.Type {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (self.locals.items[i].get(name)) |t| return t;
        }
        return self.globals.get(name);
    }
};

fn ownDisplay(state: *state_mod.CompilerState, t: ir.Type) ![]const u8 {
    const s = try ir.displayTypeAlloc(state.allocator, t);
    try state.owned.append(state.allocator, s);
    return s;
}

fn requireAssign(state: *state_mod.CompilerState, got: ir.Type, expected: ir.Type, ctx: []const u8) TypecheckError!void {
    if (ir.involvesUnknown(got) or ir.involvesUnknown(expected)) return;
    if (!ir.isSubtype(got, expected)) {
        const g = try ownDisplay(state, got);
        const e = try ownDisplay(state, expected);
        std.debug.print("CompileError: {s}: type '{s}' is not assignable to '{s}'\n", .{ ctx, g, e });
        return error.CompileError;
    }
}

fn inferLiteral(ta: ir.TypeAlloc, lit: ast.Literal) !ir.Type {
    return switch (lit.literal_type) {
        .string => try ta.arrayType(ir.TByte, lit.value.len),
        .boolean => ir.TBool,
        .@"null" => ir.TNull,
        else => ir.TInt,
    };
}

fn fieldTypeFromStruct(state: *state_mod.CompilerState, ta: ir.TypeAlloc, struct_name: []const u8, field: []const u8) !ir.Type {
    const def = state.structs.get(struct_name) orelse return ir.TUnknown;
    const raw = def.types.get(field) orelse return ir.TUnknown;
    return try ir.parseDisplayType(ta, raw);
}

fn fnReturnType(state: *state_mod.CompilerState, ta: ir.TypeAlloc, func_name: []const u8) !ir.Type {
    if (state.functions.get(func_name)) |def| {
        if (def.return_type) |rt| return try ir.parseDisplayType(ta, rt);
        if (def.node.* == .function_decl) {
            if (def.node.function_decl.return_type) |rt_node| {
                return try from_ast.typeFromAst(rt_node, state, ta);
            }
        }
    }
    return ir.TUnknown;
}

fn fnParamTypes(state: *state_mod.CompilerState, ta: ir.TypeAlloc, func_name: []const u8, out_params: *std.ArrayList(ir.Type), out_rest: *?ir.Type, out_variadic: *bool) !bool {
    const def = state.functions.get(func_name) orelse return false;
    if (def.node.* != .function_decl) return false;
    const f = &def.node.function_decl;
    const plist = switch (f.params.*) {
        .params => |p| p.params,
        else => return false,
    };
    const is_variadic = switch (f.params.*) {
        .params => |p| p.is_variadic,
        else => false,
    };
    out_variadic.* = is_variadic;
    out_rest.* = null;
    for (plist, 0..) |pnode, i| {
        if (pnode.* != .declaration) continue;
        const d = &pnode.declaration;
        var t: ir.Type = ir.TUnknown;
        if (d.type_annotation) |ann| {
            t = try from_ast.typeFromAst(ann, state, ta);
        }
        if (is_variadic and i == plist.len - 1) {
            if (t == .array) {
                out_rest.* = t;
            } else {
                const elem = if (t == .unknown) ir.TUnknown else t;
                out_rest.* = try ta.arrayType(elem, null);
            }
            continue;
        }
        try out_params.append(ta.allocator, t);
    }
    return true;
}

fn resolveCalleeName(state: *state_mod.CompilerState, call: *const ast.Call) ?[]const u8 {
    if (call.callee.* == .primary) return call.callee.primary.name;
    if (path.tryResolveStaticPath(state, call.callee) catch null) |p| return p;
    return null;
}

fn inferExpr(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    return switch (node.*) {
        .literal => |lit| try inferLiteral(ta, lit),
        .primary => |p| blk: {
            if (p.kind == .identifier or p.kind == .register) {
                if (env.lookup(p.name)) |t| break :blk t;
                if (state.global_types.get(p.name)) |gt| {
                    if (std.mem.startsWith(u8, gt, "module:")) {
                        break :blk .{ .struct_ = gt };
                    }
                    break :blk try ir.parseDisplayType(ta, gt);
                }
            }
            break :blk ir.TUnknown;
        },
        .unary => |u| blk: {
            const t = try inferExpr(state, env, ta, u.arg);
            if (std.mem.eql(u8, u.operator, "!")) break :blk ir.TBool;
            break :blk t;
        },
        .binary => |b| blk: {
            const l = try inferExpr(state, env, ta, b.left);
            const r = try inferExpr(state, env, ta, b.right);
            const op = b.operator;
            if (isCmpOrLogic(op)) {
                if (std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=")) {
                    if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                        try requireAssign(state, l, ir.TInt, "operator left");
                        try requireAssign(state, r, ir.TInt, "operator right");
                    }
                }
                break :blk ir.TBool;
            }
            if (std.mem.eql(u8, op, "+")) {
                if (ir.isByteSlice(l) or ir.isByteSlice(r)) break :blk ir.TString;
                if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                    try requireAssign(state, l, ir.TInt, "numeric +");
                    try requireAssign(state, r, ir.TInt, "numeric +");
                }
                break :blk ir.TInt;
            }
            if (isArith(op)) {
                if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                    try requireAssign(state, l, ir.TInt, "operator");
                    try requireAssign(state, r, ir.TInt, "operator");
                }
                break :blk ir.TInt;
            }
            break :blk ir.TUnknown;
        },
        .call => |*c| try inferCall(state, env, ta, node, c),
        .member => |m| blk: {
            const obj = try inferExpr(state, env, ta, m.object);
            if (obj == .struct_ and m.property.* == .primary) {
                break :blk try fieldTypeFromStruct(state, ta, obj.struct_, m.property.primary.name);
            }
            break :blk ir.TUnknown;
        },
        .index => |idx| blk: {
            const obj = try inferExpr(state, env, ta, idx.object);
            const i = try inferExpr(state, env, ta, idx.index);
            if (!ir.involvesUnknown(i)) try requireAssign(state, i, ir.TInt, "index");
            if (obj == .array) break :blk obj.array.elem.*;
            if (!ir.involvesUnknown(obj) and obj != .unknown) {
                const d = try ownDisplay(state, obj);
                std.debug.print("CompileError: Cannot index type '{s}'\n", .{d});
                return error.CompileError;
            }
            break :blk ir.TUnknown;
        },
        .array_literal => |a| try inferArrayLiteral(state, env, ta, a),
        .struct_init => |init| try inferStructInit(state, env, ta, init),
        .error_expr => |e| blk: {
            const msg = try inferExpr(state, env, ta, e.message);
            try requireAssign(state, msg, ir.TString, "error(...)");
            break :blk ir.TError;
        },
        .try_expr => |t| blk: {
            const inner = try inferExpr(state, env, ta, t.expression);
            if (!ir.involvesUnknown(inner)) {
                if (inner != .error_ and !ir.isErrorUnion(inner) and inner != .unknown) {
                    if (!ir.allowsError(inner)) {
                        const d = try ownDisplay(state, inner);
                        std.debug.print("CompileError: '?' operator used on non-error-union type '{s}'\n", .{d});
                        return error.CompileError;
                    }
                }
                if (env.annotated_return) |ar| {
                    if (!ir.allowsError(ar)) {
                        const d = try ownDisplay(state, ar);
                        std.debug.print("CompileError: Cannot use '?' here: enclosing function return type '{s}' does not allow error\n", .{d});
                        return error.CompileError;
                    }
                }
            }
            break :blk try ir.unwrapError(ta, inner);
        },
        .assignment => |a| blk: {
            const val = try inferExpr(state, env, ta, a.right);
            if (a.left.* == .primary) {
                if (env.lookup(a.left.primary.name)) |existing| {
                    try requireAssign(state, val, existing, "assignment");
                }
            } else if (a.left.* == .member) {
                const mem = a.left.member;
                const obj = try inferExpr(state, env, ta, mem.object);
                if (obj == .struct_ and mem.property.* == .primary) {
                    const ft = try fieldTypeFromStruct(state, ta, obj.struct_, mem.property.primary.name);
                    try requireAssign(state, val, ft, "assignment to field");
                }
            } else if (a.left.* == .index) {
                _ = try inferExpr(state, env, ta, a.left);
            }
            break :blk val;
        },
        .block => |b| blk: {
            try env.pushScope();
            defer env.popScope();
            var last: ir.Type = ir.TUnknown;
            for (b.statements) |s| {
                last = (try checkStmt(state, env, ta, s)) orelse ir.TUnknown;
            }
            break :blk last;
        },
        .if_expr => |i| blk: {
            _ = try inferExpr(state, env, ta, i.condition);
            _ = try inferExpr(state, env, ta, i.body);
            if (i.else_body) |e| _ = try inferExpr(state, env, ta, e);
            break :blk ir.TUnknown;
        },
        .for_expr => |f| blk: {
            if (f.condition) |c| _ = try inferExpr(state, env, ta, c);
            if (f.range_start) |s| _ = try inferExpr(state, env, ta, s);
            if (f.range_end) |e| _ = try inferExpr(state, env, ta, e);
            if (f.iterable) |it| _ = try inferExpr(state, env, ta, it);
            try env.pushScope();
            defer env.popScope();
            for (f.captures) |cap| try env.define(cap.name, ir.TInt);
            _ = try inferExpr(state, env, ta, f.body);
            break :blk ir.TUnknown;
        },
        else => ir.TUnknown,
    };
}

fn isCmpOrLogic(op: []const u8) bool {
    return std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=") or
        std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "||");
}

fn isArith(op: []const u8) bool {
    return std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or
        std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%") or
        std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**");
}

fn inferCall(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, call_node: *ast.Node, c: *const ast.Call) TypecheckError!ir.Type {
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@isError")) {
        if (c.args.len != 1) {
            std.debug.print("CompileError: @isError expects exactly 1 argument\n", .{});
            return error.CompileError;
        }
        _ = try inferExpr(state, env, ta, c.args[0]);
        return ir.TBool;
    }
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@typeOf")) {
        if (c.args.len != 1) {
            std.debug.print("CompileError: @typeOf expects exactly 1 argument\n", .{});
            return error.CompileError;
        }
        const arg_type = try inferExpr(state, env, ta, c.args[0]);
        const disp = try ownDisplay(state, arg_type);
        try state.type_of_results.put(call_node, disp);
        return ir.TString;
    }

    const name = resolveCalleeName(state, c);
    if (name == null) {
        for (c.args) |a| _ = try inferExpr(state, env, ta, a);
        return ir.TUnknown;
    }

    var params: std.ArrayList(ir.Type) = .empty;
    defer params.deinit(ta.allocator);
    var rest: ?ir.Type = null;
    var variadic = false;
    const has_sig = try fnParamTypes(state, ta, name.?, &params, &rest, &variadic);

    // Method calls with Struct::method — receiver prepended in TS; skipped for module paths.
    _ = c.args;

    if (has_sig) {
        const named_count = params.items.len;
        const any_annotated = blk: {
            for (params.items) |p| {
                if (p != .unknown) break :blk true;
            }
            break :blk false;
        };
        if (!variadic and rest == null and any_annotated and c.args.len != named_count) {
            std.debug.print("CompileError: Function '{s}' expected {d} arguments, got {d}\n", .{ name.?, named_count, c.args.len });
            return error.CompileError;
        }
        const ncheck = @min(c.args.len, named_count);
        var i: usize = 0;
        while (i < ncheck) : (i += 1) {
            const at = try inferExpr(state, env, ta, c.args[i]);
            var ctx_buf: [96]u8 = undefined;
            const ctx = std.fmt.bufPrint(&ctx_buf, "argument {d} of '{s}'", .{ i + 1, name.? }) catch "argument";
            try requireAssign(state, at, params.items[i], ctx);
        }
        while (i < c.args.len) : (i += 1) {
            _ = try inferExpr(state, env, ta, c.args[i]);
        }
    } else {
        for (c.args) |a| _ = try inferExpr(state, env, ta, a);
    }
    return try fnReturnType(state, ta, name.?);
}

fn inferArrayLiteral(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, a: ast.ArrayLiteral) TypecheckError!ir.Type {
    if (a.elements.len == 0) return try ta.arrayType(ir.TUnknown, 0);
    var types: std.ArrayList(ir.Type) = .empty;
    defer types.deinit(ta.allocator);
    for (a.elements) |el| {
        try types.append(ta.allocator, try inferExpr(state, env, ta, el));
    }
    var elem = types.items[0];
    var i: usize = 1;
    while (i < types.items.len) : (i += 1) {
        const ti = types.items[i];
        if (ir.involvesUnknown(elem) or ir.involvesUnknown(ti)) {
            if (elem == .unknown) elem = ti;
            continue;
        }
        if (elem == .array and ti == .array) {
            if (elem.array.length != null and ti.array.length != null and elem.array.length.? != ti.array.length.?) {
                std.debug.print(
                    "CompileError: Array elements have inconsistent lengths [{d}] vs [{d}]\n",
                    .{ elem.array.length.?, ti.array.length.? },
                );
                return error.CompileError;
            }
            if (!ir.isSubtype(ti.array.elem.*, elem.array.elem.*) and !ir.isSubtype(elem.array.elem.*, ti.array.elem.*)) {
                const d1 = try ownDisplay(state, elem);
                const d2 = try ownDisplay(state, ti);
                std.debug.print("CompileError: Array elements have inconsistent types '{s}' and '{s}'\n", .{ d1, d2 });
                return error.CompileError;
            }
            const len = if (elem.array.length != null) elem.array.length else ti.array.length;
            const inner = if (ir.isSubtype(ti.array.elem.*, elem.array.elem.*)) elem.array.elem.* else ti.array.elem.*;
            elem = try ta.arrayType(inner, len);
            continue;
        }
        if (!ir.isSubtype(ti, elem) and !ir.isSubtype(elem, ti)) {
            const d1 = try ownDisplay(state, elem);
            const d2 = try ownDisplay(state, ti);
            std.debug.print("CompileError: Array elements have inconsistent types '{s}' and '{s}'\n", .{ d1, d2 });
            return error.CompileError;
        }
        if (!ir.isSubtype(ti, elem)) elem = ti;
    }
    return try ta.arrayType(elem, a.elements.len);
}

fn inferStructInit(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, init: ast.StructInit) TypecheckError!ir.Type {
    var struct_name = init.name;
    if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
        struct_name = path.resolveModuleType(state, struct_name) catch struct_name;
    }
    if (!state.structs.contains(struct_name)) {
        std.debug.print("CompileError: Unknown struct '{s}'\n", .{init.name});
        return error.CompileError;
    }
    for (init.fields) |field| {
        const expected = try fieldTypeFromStruct(state, ta, struct_name, field.name);
        const got = try inferExpr(state, env, ta, field.value);
        var ctx_buf: [128]u8 = undefined;
        const ctx = std.fmt.bufPrint(&ctx_buf, "field '{s}' of '{s}'", .{ field.name, struct_name }) catch "field";
        try requireAssign(state, got, expected, ctx);
    }
    return .{ .struct_ = struct_name };
}

fn checkStmt(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!?ir.Type {
    switch (node.*) {
        .declaration => |d| {
            if (d.value.* == .import) {
                if (state.global_types.get(d.name)) |mod| {
                    if (std.mem.startsWith(u8, mod, "module:")) {
                        try env.define(d.name, .{ .struct_ = mod });
                    }
                }
                // Also check $name key style
                var key_buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "${s}", .{d.name}) catch "";
                if (state.global_types.get(key)) |mod| {
                    if (std.mem.startsWith(u8, mod, "module:")) {
                        try env.define(d.name, .{ .struct_ = mod });
                        try env.const_names.put(d.name, {});
                    }
                }
                if (d.is_const) try env.const_names.put(d.name, {});
                return null;
            }
            const value_type = try inferExpr(state, env, ta, d.value);
            if (d.type_annotation) |ann| {
                const annot = try from_ast.typeFromAst(ann, state, ta);
                var ctx_buf: [160]u8 = undefined;
                const ctx = std.fmt.bufPrint(&ctx_buf, "declaration of '{s}'", .{d.name}) catch "declaration";
                try requireAssign(state, value_type, annot, ctx);
                try env.define(d.name, annot);
                if (std.mem.indexOf(u8, d.name, "::") == null) {
                    const disp = try ownDisplay(state, annot);
                    try state.global_types.put(d.name, disp);
                }
            } else if (value_type == .struct_) {
                try env.define(d.name, value_type);
                try state.global_types.put(d.name, value_type.struct_);
            } else {
                try env.define(d.name, value_type);
            }
            if (d.is_const) try env.const_names.put(d.name, {});
            return null;
        },
        .return_expr => |r| {
            const t = if (r.return_value) |v| try inferExpr(state, env, ta, v) else ir.TNull;
            if (env.expected_return) |er| {
                try requireAssign(state, t, er, "return value");
            }
            return t;
        },
        .defer_stmt => |d| {
            _ = try checkStmt(state, env, ta, d.body);
            return null;
        },
        .function_decl, .struct_decl, .extern_decl => return null,
        .block => return try inferExpr(state, env, ta, node),
        else => {
            _ = try inferExpr(state, env, ta, node);
            return null;
        },
    }
}

fn checkFunction(state: *state_mod.CompilerState, ta: ir.TypeAlloc, f: *ast.FunctionDecl, top_consts: *const std.StringHashMap(void)) TypecheckError!void {
    var env = Env.init(ta.allocator);
    defer env.deinit();

    var cit = top_consts.keyIterator();
    while (cit.next()) |n| try env.const_names.put(n.*, {});

    var git = state.global_types.iterator();
    while (git.next()) |e| {
        const k = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (std.mem.startsWith(u8, k, "$")) continue;
        if (std.mem.startsWith(u8, v, "module:")) {
            try env.globals.put(k, .{ .struct_ = v });
        } else {
            try env.globals.put(k, try ir.parseDisplayType(ta, v));
        }
    }
    var nit = state.native_globals.keyIterator();
    while (nit.next()) |n| try env.globals.put(n.*, ir.TUnknown);

    const annotated: ?ir.Type = if (f.return_type) |rt| try from_ast.typeFromAst(rt, state, ta) else null;
    env.annotated_return = annotated;
    env.expected_return = annotated;

    try env.pushScope();
    defer env.popScope();

    const plist = switch (f.params.*) {
        .params => |p| p.params,
        else => &[_]*ast.Node{},
    };
    const is_variadic = switch (f.params.*) {
        .params => |p| p.is_variadic,
        else => false,
    };
    for (plist, 0..) |pnode, i| {
        if (pnode.* != .declaration) continue;
        const d = &pnode.declaration;
        var t: ir.Type = ir.TUnknown;
        if (d.type_annotation) |ann| t = try from_ast.typeFromAst(ann, state, ta);
        if (std.mem.eql(u8, d.name, "self")) {
            if (std.mem.indexOf(u8, f.name, "::")) |idx| {
                t = .{ .struct_ = f.name[0..idx] };
            }
        }
        if (is_variadic and i == plist.len - 1 and t != .array) {
            const elem = if (t == .unknown) ir.TUnknown else t;
            t = try ta.arrayType(elem, null);
        }
        try env.define(d.name, t);
    }

    if (f.body.* == .block) {
        for (f.body.block.statements) |s| {
            _ = try checkStmt(state, &env, ta, s);
        }
    }

    if (annotated) |a| {
        if (state.functions.getPtr(f.name)) |def| {
            def.return_type = try ownDisplay(state, a);
        }
    }
}

fn checkStructFieldTypes(state: *state_mod.CompilerState, ta: ir.TypeAlloc, s: *const ast.StructDecl) TypecheckError!void {
    const def = state.structs.getPtr(s.name) orelse return;
    for (s.fields) |field| {
        if (field.type_annotation) |ann| {
            const t = try from_ast.typeFromAst(ann, state, ta);
            const disp = try ownDisplay(state, t);
            try def.types.put(field.name, disp);
        }
    }
}

/// Gradual typecheck: validate annotated returns/params when present; Unknown otherwise.
pub fn typecheck(state: *state_mod.CompilerState, doc: *ast.Document) TypecheckError!void {
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };

    for (doc.statements) |s| {
        if (s.* == .struct_decl) try checkStructFieldTypes(state, ta, &s.struct_decl);
    }

    var top_consts = std.StringHashMap(void).init(ta.allocator);
    defer top_consts.deinit();
    for (doc.statements) |s| {
        if (s.* != .declaration) continue;
        const d = &s.declaration;
        if (d.value.* == .import or d.is_const) try top_consts.put(d.name, {});
    }

    for (doc.statements) |s| {
        if (s.* == .function_decl) {
            try checkFunction(state, ta, &s.function_decl, &top_consts);
        } else if (s.* == .struct_decl) {
            for (s.struct_decl.methods) |m| {
                if (m.* == .function_decl) try checkFunction(state, ta, &m.function_decl, &top_consts);
            }
        }
    }

    var env = Env.init(ta.allocator);
    defer env.deinit();
    try env.pushScope();
    var cit = top_consts.keyIterator();
    while (cit.next()) |n| {
        if (state.global_types.get(n.*)) |v| {
            if (std.mem.startsWith(u8, v, "module:")) try env.globals.put(n.*, .{ .struct_ = v });
        }
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "${s}", .{n.*}) catch continue;
        if (state.global_types.get(key)) |v| {
            if (std.mem.startsWith(u8, v, "module:")) try env.globals.put(n.*, .{ .struct_ = v });
        }
        try env.const_names.put(n.*, {});
    }
    var git = state.global_types.iterator();
    while (git.next()) |e| {
        const k = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (std.mem.startsWith(u8, k, "$")) continue;
        if (std.mem.startsWith(u8, v, "module:")) {
            try env.globals.put(k, .{ .struct_ = v });
        } else {
            try env.globals.put(k, try ir.parseDisplayType(ta, v));
        }
    }

    for (doc.statements) |s| {
        switch (s.*) {
            .function_decl, .struct_decl, .extern_decl => continue,
            else => _ = try checkStmt(state, &env, ta, s),
        }
    }
}
