const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const from_ast = @import("from_ast.zig");
const ir = @import("ir.zig");
const path = @import("../expr/path.zig");
const intrinsics = @import("../intrinsics.zig");
const compiler_errors = @import("../../errors/compile.zig");

pub const typeAstToDisplay = from_ast.typeAstToDisplay;

pub const TypecheckError = error{ OutOfMemory, CompileError, Overflow, InvalidCharacter };

pub const Env = struct {
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

pub fn ownDisplay(state: *state_mod.CompilerState, t: ir.Type) ![]const u8 {
    const s = try ir.displayTypeAlloc(state.allocator, t);
    try state.owned.append(state.allocator, s);
    return s;
}

fn sourceFor(state: *state_mod.CompilerState, file_path: []const u8) []const u8 {
    for (state.chunk.sources.items) |s| {
        if (std.mem.eql(u8, s.path, file_path)) return s.text;
    }
    return state.chunk.source;
}

pub fn requireAssign(state: *state_mod.CompilerState, got: ir.Type, expected: ir.Type, ctx: []const u8) TypecheckError!void {
    try requireAssignAt(state, got, expected, ctx, .{}, null);
}

pub fn requireAssignFrom(state: *state_mod.CompilerState, got: ir.Type, expected: ir.Type, ctx: []const u8, from: ?*ast.Node) TypecheckError!void {
    const loc = if (from) |n| n.loc() else ast.Location{};
    try requireAssignAt(state, got, expected, ctx, loc, from);
}

fn requireAssignAt(state: *state_mod.CompilerState, got: ir.Type, expected: ir.Type, ctx: []const u8, loc: ast.Location, from: ?*ast.Node) TypecheckError!void {
    if (ir.involvesUnknown(got) or ir.involvesUnknown(expected)) return;
    if (ir.isSubtype(got, expected)) return;
    // Whole enum value → literal field only when RHS is that static variant.
    if (got == .enum_ and expected == .enum_lit) {
        if (std.mem.eql(u8, got.enum_, expected.enum_lit.enum_name)) {
            if (from) |node| {
                if (isEnumVariantValue(state, node, expected.enum_lit.enum_name, expected.enum_lit.variant)) return;
            }
        }
    }
    // Value literal types / `@type` wrapping them (incl. unions of literals): matching literal RHS.
    if (from) |node| {
        if (matchesValueLiteralToType(node, expected)) return;
    }
    // Zig-style: integer literals may coerce into any integer width that fits.
    if (ir.isInteger(ir.peelDefined(expected)) and got == .i64) {
        if (from) |node| {
            if (intLiteralFits(node, ir.widthOf(expected).?)) return;
        }
    }
    // Float literals are f64; may coerce into f32.
    if (ir.peelDefined(expected) == .f32 and got == .f64) {
        if (from) |node| {
            if (isFloatLiteral(node)) return;
        }
    }
    const g = try ownDisplay(state, got);
    const e = try ownDisplay(state, expected);
    if (loc.line > 0 or loc.path.len > 0) {
        const file_path = if (loc.path.len > 0) loc.path else state.chunk.file;
        const line = if (loc.line > 0) loc.line else 1;
        const col = if (loc.column > 0) loc.column else 1;
        return compiler_errors.compileFailAt(
            state,
            file_path,
            sourceFor(state, file_path),
            line,
            col,
            "{s}: type '{s}' is not assignable to '{s}' (use @as)",
            .{ ctx, g, e },
        );
    }
    return compiler_errors.compileFailFmt(state, "{s}: type '{s}' is not assignable to '{s}' (use @as)", .{ ctx, g, e });
}

fn matchesValueLiteralToType(node: *ast.Node, expected: ir.Type) bool {
    const exp = ir.peelDefined(expected);
    if (exp == .union_) {
        for (exp.union_) |arm| {
            if (matchesValueLiteralToType(node, arm)) return true;
        }
        return false;
    }
    return matchesValueLiteral(node, exp);
}

fn matchesValueLiteral(node: *ast.Node, expected: ir.Type) bool {
    if (node.* != .literal) return false;
    const lit = node.literal;
    return switch (expected) {
        .str_lit => lit.literal_type == .string and std.mem.eql(u8, lit.value, expected.str_lit),
        .bool_lit => lit.literal_type == .boolean and std.mem.eql(u8, lit.value, if (expected.bool_lit) "true" else "false"),
        .int_lit => blk: {
            const n: i64 = switch (lit.literal_type) {
                .number => std.fmt.parseInt(i64, lit.value, 10) catch break :blk false,
                .hex => std.fmt.parseInt(i64, lit.value[2..], 16) catch break :blk false,
                .octal => std.fmt.parseInt(i64, lit.value[2..], 8) catch break :blk false,
                .binary => std.fmt.parseInt(i64, lit.value[2..], 2) catch break :blk false,
                else => break :blk false,
            };
            break :blk n == expected.int_lit;
        },
        else => false,
    };
}

fn intLiteralFits(node: *ast.Node, width: @import("../widths.zig").Width) bool {
    if (node.* != .literal) return false;
    const lit = node.literal;
    const n: i64 = switch (lit.literal_type) {
        .number => blk: {
            if (std.mem.indexOfScalar(u8, lit.value, '.') != null) return false;
            break :blk std.fmt.parseInt(i64, lit.value, 10) catch return false;
        },
        .hex => std.fmt.parseInt(i64, lit.value[2..], 16) catch return false,
        .octal => std.fmt.parseInt(i64, lit.value[2..], 8) catch return false,
        .binary => std.fmt.parseInt(i64, lit.value[2..], 2) catch return false,
        else => return false,
    };
    return @import("../widths.zig").i64Fits(width, n);
}

fn isFloatLiteral(node: *ast.Node) bool {
    if (node.* != .literal) return false;
    const lit = node.literal;
    if (lit.literal_type != .number) return false;
    return std.mem.indexOfScalar(u8, lit.value, '.') != null or
        std.mem.indexOfScalar(u8, lit.value, 'e') != null or
        std.mem.indexOfScalar(u8, lit.value, 'E') != null;
}

fn isEnumVariantValue(state: *state_mod.CompilerState, node: *ast.Node, enum_name: []const u8, variant: []const u8) bool {
    if (node.* != .member) return false;
    const mem = node.member;
    if (mem.property.* != .primary) return false;
    if (!std.mem.eql(u8, mem.property.primary.name, variant)) return false;
    const ename = from_ast.resolveEnumName(state, mem.object) orelse return false;
    return std.mem.eql(u8, ename, enum_name);
}

fn isNumericType(t: ir.Type) bool {
    return ir.isNumeric(t);
}

/// Same-width numeric ops only (no implicit int↔float or f32↔f64).
fn requireNumericPair(state: *state_mod.CompilerState, l: ir.Type, r: ir.Type, ctx: []const u8) TypecheckError!ir.Type {
    if (!isNumericType(l) or !isNumericType(r)) {
        const dl = try ownDisplay(state, l);
        const dr = try ownDisplay(state, r);
        return compiler_errors.compileFailFmt(state, "{s}: expected matching numeric types, got '{s}' and '{s}'", .{ ctx, dl, dr });
    }
    if (!ir.typeEquals(l, r)) {
        const dl = try ownDisplay(state, l);
        const dr = try ownDisplay(state, r);
        return compiler_errors.compileFailFmt(state, "{s}: mixed '{s}' and '{s}' (use @as)", .{ ctx, dl, dr });
    }
    return l;
}

fn inferLiteral(ta: ir.TypeAlloc, lit: ast.Literal) !ir.Type {
    return switch (lit.literal_type) {
        .string => try ta.arrayType(ir.TByte, lit.value.len),
        .boolean => ir.TBool,
        .null => ir.TNull,
        .number => blk: {
            if (std.mem.indexOfScalar(u8, lit.value, '.') != null or
                std.mem.indexOfScalar(u8, lit.value, 'e') != null or
                std.mem.indexOfScalar(u8, lit.value, 'E') != null)
            {
                break :blk ir.TF64;
            }
            break :blk ir.TInt;
        },
        else => ir.TInt,
    };
}

fn fieldTypeFromStruct(state: *state_mod.CompilerState, ta: ir.TypeAlloc, struct_name: []const u8, field: []const u8) !ir.Type {
    const def = state.structs.get(struct_name) orelse return ir.TUnknown;
    const raw = def.types.get(field) orelse return ir.TUnknown;
    return try from_ast.parseDisplayType(state, ta, raw, null);
}

/// Field type on a struct union. Discriminant `kind` with enum literals → parent enum.
fn fieldTypeFromUnion(state: *state_mod.CompilerState, ta: ir.TypeAlloc, union_t: ir.Type, field: []const u8) !ir.Type {
    if (union_t != .union_) return ir.TUnknown;
    var field_types: std.ArrayList(ir.Type) = .empty;
    defer field_types.deinit(ta.allocator);
    var enum_parent: ?[]const u8 = null;
    var all_kind_lits = std.mem.eql(u8, field, "kind");

    for (union_t.union_) |arm| {
        const sname = ir.structNameOf(arm) orelse return ir.TUnknown;
        const def = state.structs.get(sname) orelse return ir.TUnknown;
        if (def.types.get(field) == null) return ir.TUnknown;
        const ft = try fieldTypeFromStruct(state, ta, sname, field);
        if (ft == .unknown) return ir.TUnknown;
        if (all_kind_lits) {
            if (ft == .enum_lit) {
                if (enum_parent) |ep| {
                    if (!std.mem.eql(u8, ep, ft.enum_lit.enum_name)) all_kind_lits = false;
                } else {
                    enum_parent = ft.enum_lit.enum_name;
                }
            } else {
                all_kind_lits = false;
            }
        }
        try field_types.append(ta.allocator, ft);
    }
    if (field_types.items.len == 0) return ir.TUnknown;
    if (all_kind_lits) {
        if (enum_parent) |ep| return .{ .enum_ = ep };
    }
    // All equal → that type; else union of field types.
    const first = field_types.items[0];
    for (field_types.items[1..]) |ft| {
        if (!ir.typeEquals(first, ft)) {
            return try ta.unionType(field_types.items);
        }
    }
    return first;
}

const KindNarrow = struct {
    subject: []const u8,
    enum_name: []const u8,
    map: std.StringHashMap([]const u8),
};

fn kindSwitchNarrowing(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *Env,
    condition: *ast.Node,
) TypecheckError!?KindNarrow {
    _ = ta;
    if (condition.* != .member) return null;
    const mem = condition.member;
    if (mem.property.* != .primary or !std.mem.eql(u8, mem.property.primary.name, "kind")) return null;
    if (mem.object.* != .primary) return null;
    const subject = mem.object.primary.name;
    var obj_t = env.lookup(subject) orelse return null;
    if (obj_t == .defined) obj_t = obj_t.defined.underlying.*;
    if (obj_t != .union_) return null;
    const disp = try ownDisplay(state, obj_t);
    const info = (try from_ast.discrimVariantMap(state, state.allocator, disp)) orelse return null;
    return .{ .subject = subject, .enum_name = info.enum_name, .map = info.map };
}

fn resolveSwitchVariant(state: *state_mod.CompilerState, pat: *ast.Node, enum_name: []const u8) ?[]const u8 {
    if (pat.* != .member) return null;
    const mem = &pat.member;
    if (mem.property.* != .primary) return null;
    const ename = from_ast.resolveEnumName(state, mem.object) orelse return null;
    if (!std.mem.eql(u8, ename, enum_name)) return null;
    if (state.enums.get(ename)) |ed| {
        if (!ed.variants.contains(mem.property.primary.name)) return null;
    } else return null;
    return mem.property.primary.name;
}

/// Remaining discrim arms after named patterns are covered (for `@else` narrowing).
fn remainingNarrowType(
    ta: ir.TypeAlloc,
    n: KindNarrow,
    covered: *const std.StringHashMap(void),
) TypecheckError!?ir.Type {
    var arms: std.ArrayList(ir.Type) = .empty;
    defer arms.deinit(ta.allocator);
    var it = n.map.iterator();
    while (it.next()) |e| {
        if (!covered.contains(e.key_ptr.*)) {
            try arms.append(ta.allocator, .{ .struct_ = e.value_ptr.* });
        }
    }
    if (arms.items.len == 0) return null;
    if (arms.items.len == 1) return arms.items[0];
    return try ta.unionType(arms.items);
}

fn fnReturnType(state: *state_mod.CompilerState, ta: ir.TypeAlloc, func_name: []const u8) !ir.Type {
    if (state.functions.get(func_name)) |def| {
        if (def.return_type) |rt| return try from_ast.parseDisplayType(state, ta, rt, null);
        if (def.node.* == .function_decl) {
            if (def.node.function_decl.return_type) |rt_node| {
                return try from_ast.typeFromAst(rt_node, state, ta);
            }
        }
    }
    return ir.TUnknown;
}

fn resolveMethodSelfType(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    struct_name: []const u8,
    has_annotation: bool,
    annotated: ir.Type,
) TypecheckError!ir.Type {
    const bare: ir.Type = .{ .struct_ = struct_name };
    if (!has_annotation) return try ta.ptrType(bare);
    if (annotated == .struct_ and std.mem.eql(u8, annotated.struct_, struct_name)) return annotated;
    if (annotated == .ptr and annotated.ptr.* == .struct_ and std.mem.eql(u8, annotated.ptr.*.struct_, struct_name))
        return annotated;
    const d = try ownDisplay(state, annotated);
    return compiler_errors.compileFailFmt(
        state,
        "method self must be '{s}' or '*{s}', got '{s}'",
        .{ struct_name, struct_name, d },
    );
}

fn requireMethodReceiver(
    state: *state_mod.CompilerState,
    got: ir.Type,
    expected: ir.Type,
    method_name: []const u8,
    from: ?*ast.Node,
) TypecheckError!void {
    if (ir.involvesUnknown(got) or ir.involvesUnknown(expected)) return;
    if (ir.isSubtype(got, expected)) return;
    // Zig-style: value receiver auto-& into *T; *T auto-deref into value receiver.
    if (expected == .ptr and got == .struct_) {
        if (expected.ptr.* == .struct_ and std.mem.eql(u8, got.struct_, expected.ptr.*.struct_)) return;
    }
    if (got == .ptr and expected == .struct_) {
        if (got.ptr.* == .struct_ and std.mem.eql(u8, got.ptr.*.struct_, expected.struct_)) return;
    }
    if (ir.optionalPayload(got)) |payload| {
        return requireMethodReceiver(state, payload, expected, method_name, from);
    }
    const g = try ownDisplay(state, got);
    const e = try ownDisplay(state, expected);
    return compiler_errors.compileFailFmt(
        state,
        "method '{s}' receiver: type '{s}' is not assignable to '{s}'",
        .{ method_name, g, e },
    );
}

fn resolveMethodCallee(
    state: *state_mod.CompilerState,
    env: *Env,
    ta: ir.TypeAlloc,
    c: *const ast.Call,
) TypecheckError!?struct { name: []const u8, receiver: *ast.Node } {
    if (c.callee.* != .member) return null;
    const mem = c.callee.member;
    if (mem.property.* != .primary) return null;
    const prop = mem.property.primary.name;
    const obj_ty = try inferExpr(state, env, ta, mem.object);
    const sname = ir.structNameOf(obj_ty) orelse return null;
    if (state.structs.get(sname)) |sd| {
        if (sd.offsets.contains(prop)) return null; // field, not method
    }
    const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ sname, prop });
    try state.owned.append(state.allocator, method_name);
    if (!state.functions.contains(method_name)) return null;
    return .{ .name = method_name, .receiver = mem.object };
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
    const method_struct: ?[]const u8 = blk: {
        if (std.mem.indexOf(u8, f.name, "::")) |idx| {
            const sname = f.name[0..idx];
            if (state.structs.contains(sname)) break :blk sname;
        }
        break :blk null;
    };
    for (plist, 0..) |pnode, i| {
        var t: ir.Type = ir.TUnknown;
        if (pnode.type_annotation) |ann| {
            t = try from_ast.typeFromAst(ann, state, ta);
        }
        if (method_struct) |sname| {
            if (i == 0 and std.mem.eql(u8, pnode.name, "self")) {
                t = try resolveMethodSelfType(state, ta, sname, pnode.type_annotation != null, t);
            }
        }

        const is_rest = pnode.is_rest;
        if (is_rest and i != plist.len - 1) {
            return compiler_errors.compileFailFmt(state, "Rest parameter must be the last parameter", .{});
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

fn noteDiag(state: *state_mod.CompilerState, node: *ast.Node) void {
    const loc = node.loc();
    if (loc.line > 0) state.diag_line = loc.line;
    if (loc.column > 0) state.diag_column = loc.column;
    if (loc.path.len > 0) state.diag_path = loc.path;
}

pub fn inferExpr(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    noteDiag(state, node);
    return switch (node.*) {
        .literal => |lit| try inferLiteral(ta, lit),
        .primary => |p| blk: {
            if (p.kind == .identifier or p.kind == .register) {
                if (env.lookup(p.name)) |t| break :blk t;
                if (state.global_types.get(p.name)) |gt| {
                    if (std.mem.startsWith(u8, gt, "module:")) {
                        break :blk .{ .struct_ = gt };
                    }
                    break :blk try from_ast.parseDisplayType(state, ta, gt, null);
                }
            }
            break :blk ir.TUnknown;
        },
        .unary => |u| blk: {
            const t = try inferExpr(state, env, ta, u.arg);
            if (std.mem.eql(u8, u.operator, "!")) break :blk ir.TBool;
            if (std.mem.eql(u8, u.operator, "&")) {
                if (ir.involvesUnknown(t)) break :blk ir.TUnknown;
                if (t == .ptr) {
                    return compiler_errors.compileFailFmt(state, "cannot take address of a pointer (no **T yet)", .{});
                }
                if (ir.optionalPayload(t) != null) {
                    return compiler_errors.compileFailFmt(state, "cannot take address of an optional; use a non-optional struct value", .{});
                }
                if (t != .struct_) {
                    const d = try ownDisplay(state, t);
                    return compiler_errors.compileFailFmt(state, "address-of requires a struct value, got '{s}'", .{d});
                }
                break :blk try ta.ptrType(t);
            }
            break :blk t;
        },
        .binary => |b| blk: {
            const l = try inferExpr(state, env, ta, b.left);
            const r = try inferExpr(state, env, ta, b.right);
            const op = b.operator;
            if (isCmpOrLogic(op)) {
                if (std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=")) {
                    if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                        _ = try requireNumericPair(state, l, r, "comparison");
                    }
                }
                break :blk ir.TBool;
            }
            if (std.mem.eql(u8, op, "+")) {
                if (ir.isByteSlice(l) or ir.isByteSlice(r)) break :blk ir.TString;
                if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                    break :blk try requireNumericPair(state, l, r, "numeric +");
                }
                break :blk ir.TInt;
            }
            if (isArith(op)) {
                if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                    break :blk try requireNumericPair(state, l, r, "operator");
                }
                break :blk ir.TInt;
            }
            break :blk ir.TUnknown;
        },
        .call => |*c| try inferCall(state, env, ta, node, c),
        .member => |m| blk: {
            if (m.property.* == .primary) {
                if (from_ast.resolveEnumName(state, m.object)) |ename| {
                    if (state.enums.get(ename)) |ed| {
                        if (!ed.variants.contains(m.property.primary.name)) {
                            return compiler_errors.compileFailFmt(state, "Unknown enum variant '{s}' on '{s}'", .{ m.property.primary.name, ename });
                        }
                        // Value `Enum.Variant` has parent enum type; singleton `Enum.Variant` is a *type* annotation.
                        break :blk .{ .enum_ = ename };
                    }
                }
            }
            const obj = try inferExpr(state, env, ta, m.object);
            if (m.property.* == .primary) {
                var field_obj = obj;
                if (field_obj == .defined) field_obj = field_obj.defined.underlying.*;
                if (ir.structNameOf(field_obj)) |sname| {
                    if (state.structs.get(sname)) |def| {
                        if (def.types.get(m.property.primary.name) == null) {
                            return compiler_errors.compileFailFmt(state, "Field '{s}' does not exist on '{s}'", .{ m.property.primary.name, sname });
                        }
                    }
                    break :blk try fieldTypeFromStruct(state, ta, sname, m.property.primary.name);
                }
                if (field_obj == .union_) {
                    const ft = try fieldTypeFromUnion(state, ta, field_obj, m.property.primary.name);
                    // Hard reject only for discrim struct unions (`Literal | Add`).
                    // Error unions (`T | error`) still allow gradual field access.
                    if (ft == .unknown) {
                        const d = try ownDisplay(state, field_obj);
                        if (try from_ast.discrimVariantMap(state, state.allocator, d)) |info_owned| {
                            var info = info_owned;
                            info.map.deinit();
                            return compiler_errors.compileFailFmt(state, "Field '{s}' is not available on all arms of '{s}' (narrow with @switch on .kind)", .{ m.property.primary.name, d });
                        }
                    }
                    break :blk ft;
                }
            }
            break :blk ir.TUnknown;
        },
        .index => |idx| blk: {
            const obj = try inferExpr(state, env, ta, idx.object);
            if (idx.is_slice) {
                if (idx.index) |start_node| {
                    const i = try inferExpr(state, env, ta, start_node);
                    if (!ir.involvesUnknown(i)) try requireAssign(state, i, ir.TInt, "slice start");
                }
                if (idx.end) |end_node| {
                    const e = try inferExpr(state, env, ta, end_node);
                    if (!ir.involvesUnknown(e)) try requireAssign(state, e, ir.TInt, "slice end");
                }
                if (obj == .array) {
                    break :blk try ta.arrayType(obj.array.elem.*, null);
                }
                if (!ir.involvesUnknown(obj) and obj != .unknown) {
                    const d = try ownDisplay(state, obj);
                    return compiler_errors.compileFailFmt(state, "Cannot slice type '{s}'", .{d});
                }
                break :blk ir.TUnknown;
            }
            const start_node = idx.index orelse {
                return compiler_errors.compileFailFmt(state, "Expected index expression", .{});
            };
            const i = try inferExpr(state, env, ta, start_node);
            if (!ir.involvesUnknown(i)) try requireAssign(state, i, ir.TInt, "index");
            if (obj == .array) break :blk obj.array.elem.*;
            if (!ir.involvesUnknown(obj) and obj != .unknown) {
                const d = try ownDisplay(state, obj);
                return compiler_errors.compileFailFmt(state, "Cannot index type '{s}'", .{d});
            }
            break :blk ir.TUnknown;
        },
        .array_literal => |a| try inferArrayLiteral(state, env, ta, a),
        .struct_init => |init| try inferStructInit(state, env, ta, init),
        .error_expr => |e| blk: {
            if (e.args.len == 0 or e.args.len > 2) {
                return compiler_errors.compileFailFmt(state, "error() takes at most 2 arguments (message, payload)", .{});
            }
            const msg = try inferExpr(state, env, ta, e.args[0]);
            try requireAssign(state, msg, ir.TString, "error(...)");
            if (e.args.len == 2) {
                _ = try inferExpr(state, env, ta, e.args[1]);
            }
            break :blk ir.TError;
        },
        .try_expr => |t| blk: {
            const inner = try inferExpr(state, env, ta, t.expression);
            if (!ir.involvesUnknown(inner)) {
                if (inner != .error_ and !ir.isErrorUnion(inner) and inner != .unknown) {
                    if (!ir.allowsError(inner)) {
                        const d = try ownDisplay(state, inner);
                        return compiler_errors.compileFailFmt(state, "'?' operator used on non-error-union type '{s}'", .{d});
                    }
                }
                if (env.annotated_return) |ar| {
                    if (!ir.allowsError(ar)) {
                        const d = try ownDisplay(state, ar);
                        return compiler_errors.compileFailFmt(state, "Cannot use '?' here: enclosing function return type '{s}' does not allow error", .{d});
                    }
                }
            }
            break :blk try ir.unwrapError(ta, inner);
        },
        .assignment => |a| blk: {
            const val = try inferExpr(state, env, ta, a.right);
            if (a.left.* == .primary) {
                if (env.lookup(a.left.primary.name)) |existing| {
                    try requireAssignFrom(state, val, existing, "assignment", a.right);
                }
            } else if (a.left.* == .member) {
                const mem = a.left.member;
                const obj = try inferExpr(state, env, ta, mem.object);
                if (mem.property.* == .primary) {
                    if (ir.structNameOf(obj)) |sname| {
                        const ft = try fieldTypeFromStruct(state, ta, sname, mem.property.primary.name);
                        try requireAssignFrom(state, val, ft, "assignment to field", a.right);
                    }
                }
            } else if (a.left.* == .index) {
                if (a.left.index.is_slice) {
                    return compiler_errors.compileFailFmt(state, "Cannot assign to a slice view", .{});
                }
                const obj_t = try inferExpr(state, env, ta, a.left.index.object);
                const start_node = a.left.index.index orelse {
                    return compiler_errors.compileFailFmt(state, "Expected index expression", .{});
                };
                const i = try inferExpr(state, env, ta, start_node);
                if (!ir.involvesUnknown(i)) try requireAssign(state, i, ir.TInt, "index");
                if (obj_t == .array) {
                    try requireAssignFrom(state, val, obj_t.array.elem.*, "assignment to index", a.right);
                }
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
            if (b.label != null) {
                break :blk try joinBreakTypes(state, env, ta, node);
            }
            break :blk last;
        },
        .if_expr => |i| blk: {
            _ = try inferExpr(state, env, ta, i.condition);
            _ = try inferExpr(state, env, ta, i.body);
            if (i.else_body) |e| _ = try inferExpr(state, env, ta, e);
            // Value-producing if (has else) joins break payload types.
            if (i.else_body != null) {
                break :blk try joinBreakTypes(state, env, ta, node);
            }
            break :blk ir.TUnknown;
        },
        .switch_expr => |sw| blk: {
            _ = try inferExpr(state, env, ta, sw.condition);
            // Narrow subject when switching on `e.kind` for a discrim struct union.
            var narrow = try kindSwitchNarrowing(state, ta, env, sw.condition);
            defer if (narrow) |*n| n.map.deinit();

            var covered = std.StringHashMap(void).init(ta.allocator);
            defer covered.deinit();
            if (narrow) |n| {
                for (sw.prongs) |prong| {
                    if (prong.is_else) continue;
                    for (prong.patterns) |pat| {
                        if (resolveSwitchVariant(state, pat, n.enum_name)) |vname| {
                            try covered.put(vname, {});
                        }
                    }
                }
            }

            // Join break payloads while still narrowed (do not re-walk after scopes pop).
            var acc: ?ir.Type = null;
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| _ = try inferExpr(state, env, ta, pat);
                try env.pushScope();
                defer env.popScope();
                if (narrow) |n| {
                    if (prong.is_else) {
                        if (try remainingNarrowType(ta, n, &covered)) |rt| {
                            try env.define(n.subject, rt);
                        }
                    } else if (prong.patterns.len == 1) {
                        if (resolveSwitchVariant(state, prong.patterns[0], n.enum_name)) |vname| {
                            if (n.map.get(vname)) |sname| {
                                try env.define(n.subject, .{ .struct_ = sname });
                            }
                        }
                    }
                }
                _ = try inferExpr(state, env, ta, prong.body);
                try walkBreakValues(state, env, ta, prong.body, &acc);
            }
            break :blk acc orelse ir.TUnknown;
        },
        .for_expr => |f| blk: {
            const expr_type = try inferExpr(state, env, ta, f.expr);
            try env.pushScope();
            defer env.popScope();
            if (f.captures.len > 0) {
                if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..")) {
                    for (f.captures) |cap| try env.define(cap.name, ir.TInt);
                } else {
                    const elem_type = if (expr_type == .array) expr_type.array.elem.* else ir.TUnknown;
                    try env.define(f.captures[0].name, elem_type);
                    if (f.captures.len > 1) {
                        try env.define(f.captures[1].name, ir.TInt);
                    }
                }
            }
            _ = try inferExpr(state, env, ta, f.body);
            break :blk ir.TUnknown;
        },
        .break_expr => |br| blk: {
            if (br.value) |v| break :blk try inferExpr(state, env, ta, v);
            break :blk ir.TUnknown;
        },
        else => ir.TUnknown,
    };
}

fn joinBreakTypes(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    var acc: ?ir.Type = null;
    try walkBreakValues(state, env, ta, node, &acc);
    return acc orelse ir.TUnknown;
}

fn walkBreakValues(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node, acc: *?ir.Type) TypecheckError!void {
    switch (node.*) {
        .break_expr => |br| {
            if (br.value) |v| {
                const t = try inferExpr(state, env, ta, v);
                if (acc.*) |cur| {
                    if (!ir.isSubtype(t, cur) and !ir.isSubtype(cur, t)) {
                        // Gradual: widen to unknown on conflict unless either side is unknown.
                        if (!ir.involvesUnknown(t) and !ir.involvesUnknown(cur) and !ir.typeEquals(t, cur)) {
                            acc.* = ir.TUnknown;
                        }
                    } else if (ir.isSubtype(cur, t)) {
                        acc.* = t;
                    }
                } else {
                    acc.* = t;
                }
            }
        },
        .block => |b| {
            for (b.statements) |s| try walkBreakValues(state, env, ta, s, acc);
        },
        .if_expr => |i| {
            try walkBreakValues(state, env, ta, i.body, acc);
            if (i.else_body) |e| try walkBreakValues(state, env, ta, e, acc);
        },
        .switch_expr => |sw| {
            for (sw.prongs) |p| try walkBreakValues(state, env, ta, p.body, acc);
        },
        .for_expr => |f| try walkBreakValues(state, env, ta, f.body, acc),
        .declaration => |d| try walkBreakValues(state, env, ta, d.value, acc),
        else => {},
    }
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
    if (c.callee.* == .primary and std.mem.startsWith(u8, c.callee.primary.name, "@")) {
        const name = c.callee.primary.name;
        if (intrinsics.match(name)) |i| {
            return try intrinsics.typecheck(state, env, ta, i, call_node, c);
        }
        return compiler_errors.compileFailFmt(state, "unknown intrinsic '{s}'", .{name});
    }

    const method = try resolveMethodCallee(state, env, ta, c);
    const name: ?[]const u8 = if (method) |m| m.name else resolveCalleeName(state, c);
    if (name == null) {
        for (c.args) |a| _ = try inferExpr(state, env, ta, a);
        return ir.TUnknown;
    }

    var params: std.ArrayList(ir.Type) = .empty;
    defer params.deinit(ta.allocator);
    var rest: ?ir.Type = null;
    var variadic = false;
    const has_sig = try fnParamTypes(state, ta, name.?, &params, &rest, &variadic);

    if (has_sig) {
        const named_count = params.items.len;
        const any_annotated = blk: {
            for (params.items) |p| {
                if (p != .unknown) break :blk true;
            }
            break :blk false;
        };
        if (method) |m| {
            // Receiver is prepended; user args must match params after self.
            const expected_user = if (named_count > 0) named_count - 1 else 0;
            if (!variadic and rest == null and any_annotated and c.args.len != expected_user) {
                return compiler_errors.compileFailFmt(state, "Function '{s}' expected {d} arguments, got {d}", .{ name.?, expected_user, c.args.len });
            }
            if (named_count > 0) {
                const recv_ty = try inferExpr(state, env, ta, m.receiver);
                try requireMethodReceiver(state, recv_ty, params.items[0], name.?, m.receiver);
            }
            const ncheck = @min(c.args.len, if (named_count > 0) named_count - 1 else 0);
            var i: usize = 0;
            while (i < ncheck) : (i += 1) {
                const at = try inferExpr(state, env, ta, c.args[i]);
                var ctx_buf: [96]u8 = undefined;
                const ctx = std.fmt.bufPrint(&ctx_buf, "argument {d} of '{s}'", .{ i + 1, name.? }) catch "argument";
                try requireAssignFrom(state, at, params.items[i + 1], ctx, c.args[i]);
            }
            while (i < c.args.len) : (i += 1) {
                _ = try inferExpr(state, env, ta, c.args[i]);
            }
        } else {
            if (!variadic and rest == null and any_annotated and c.args.len != named_count) {
                return compiler_errors.compileFailFmt(state, "Function '{s}' expected {d} arguments, got {d}", .{ name.?, named_count, c.args.len });
            }
            const ncheck = @min(c.args.len, named_count);
            var i: usize = 0;
            while (i < ncheck) : (i += 1) {
                const at = try inferExpr(state, env, ta, c.args[i]);
                var ctx_buf: [96]u8 = undefined;
                const ctx = std.fmt.bufPrint(&ctx_buf, "argument {d} of '{s}'", .{ i + 1, name.? }) catch "argument";
                try requireAssignFrom(state, at, params.items[i], ctx, c.args[i]);
            }
            while (i < c.args.len) : (i += 1) {
                _ = try inferExpr(state, env, ta, c.args[i]);
            }
        }
    } else {
        if (method) |m| _ = try inferExpr(state, env, ta, m.receiver);
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
                return compiler_errors.compileFailFmt(
                    state,
                    "Array elements have inconsistent lengths [{d}] vs [{d}]",
                    .{ elem.array.length.?, ti.array.length.? },
                );
            }
            if (!ir.isSubtype(ti.array.elem.*, elem.array.elem.*) and !ir.isSubtype(elem.array.elem.*, ti.array.elem.*)) {
                const d1 = try ownDisplay(state, elem);
                const d2 = try ownDisplay(state, ti);
                return compiler_errors.compileFailFmt(state, "Array elements have inconsistent types '{s}' and '{s}'", .{ d1, d2 });
            }
            const len = if (elem.array.length != null) elem.array.length else ti.array.length;
            const inner = if (ir.isSubtype(ti.array.elem.*, elem.array.elem.*)) elem.array.elem.* else ti.array.elem.*;
            elem = try ta.arrayType(inner, len);
            continue;
        }
        if (!ir.isSubtype(ti, elem) and !ir.isSubtype(elem, ti)) {
            const d1 = try ownDisplay(state, elem);
            const d2 = try ownDisplay(state, ti);
            return compiler_errors.compileFailFmt(state, "Array elements have inconsistent types '{s}' and '{s}'", .{ d1, d2 });
        }
        if (!ir.isSubtype(ti, elem)) elem = ti;
    }
    return try ta.arrayType(elem, a.elements.len);
}

fn inferStructInit(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, init: ast.StructInit) TypecheckError!ir.Type {
    const sn = from_ast.resolveStructName(state, init.type_expr) orelse {
        return compiler_errors.compileFailFmt(state, "Invalid struct initialization type", .{});
    };
    var struct_name = sn;
    if (std.mem.indexOfScalar(u8, struct_name, '.') != null) {
        struct_name = path.resolveModuleType(state, struct_name) catch struct_name;
    }
    try from_ast.checkStructInitExport(state, init.type_expr, struct_name);
    if (!state.structs.contains(struct_name)) {
        return compiler_errors.compileFailFmt(state, "Unknown struct '{s}'", .{sn});
    }
    for (init.fields) |field| {
        const expected = try fieldTypeFromStruct(state, ta, struct_name, field.name);
        const got = try inferExpr(state, env, ta, field.value);
        var ctx_buf: [128]u8 = undefined;
        const ctx = std.fmt.bufPrint(&ctx_buf, "field '{s}' of '{s}'", .{ field.name, struct_name }) catch "field";
        try requireAssignFrom(state, got, expected, ctx, field.value);
    }
    return .{ .struct_ = struct_name };
}

fn checkStmt(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!?ir.Type {
    noteDiag(state, node);
    switch (node.*) {
        .declaration => |d| {
            if (d.value.* == .call and d.value.call.callee.* == .primary and std.mem.eql(u8, d.value.call.callee.primary.name, "@import")) {
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
                try requireAssignAt(state, value_type, annot, ctx, d.loc, d.value);
                try env.define(d.name, annot);
                if (std.mem.indexOf(u8, d.name, "::") == null) {
                    const disp = try ownDisplay(state, annot);
                    try state.global_types.put(d.name, disp);
                }
            } else if (value_type == .struct_) {
                try env.define(d.name, value_type);
                try state.global_types.put(d.name, value_type.struct_);
            } else if (value_type == .enum_ or value_type == .enum_lit) {
                try env.define(d.name, value_type);
                const disp = try ownDisplay(state, value_type);
                try state.global_types.put(d.name, disp);
            } else {
                try env.define(d.name, value_type);
                // Persist pointer / array displays so emit can resolve field layout.
                // Skip `error` — builtin `error` struct would steal LOAD_FIELD from runtime errors.
                if (std.mem.indexOf(u8, d.name, "::") == null and
                    (value_type == .ptr or value_type == .array))
                {
                    const disp = try ownDisplay(state, value_type);
                    try state.global_types.put(d.name, disp);
                }
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
        .function_decl, .struct_decl, .enum_decl, .type_decl, .extern_decl => return null,
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
            try env.globals.put(k, try from_ast.parseDisplayType(state, ta, v, null));
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
        else => &[_]ast.Param{},
    };
    const is_variadic = switch (f.params.*) {
        .params => |p| p.is_variadic,
        else => false,
    };
    for (plist, 0..) |pnode, i| {
        var t: ir.Type = ir.TUnknown;
        if (pnode.type_annotation) |ann| t = try from_ast.typeFromAst(ann, state, ta);
        if (std.mem.indexOf(u8, f.name, "::")) |idx| {
            const sname = f.name[0..idx];
            // Module-qualified free funcs use `path.lls::name`; only bare struct names are methods.
            if (state.structs.contains(sname) and i == 0) {
                if (!std.mem.eql(u8, pnode.name, "self")) {
                    return compiler_errors.compileFailFmt(state, "method '{s}' must have first parameter named 'self'", .{f.name});
                }
                t = try resolveMethodSelfType(state, ta, sname, pnode.type_annotation != null, t);
            }
        }

        const is_rest = pnode.is_rest;
        if (is_rest and i != plist.len - 1) {
            return compiler_errors.compileFailFmt(state, "Rest parameter must be the last parameter", .{});
        }

        if (is_variadic and i == plist.len - 1 and t != .array) {
            const elem = if (t == .unknown) ir.TUnknown else t;
            t = try ta.arrayType(elem, null);
        }
        try env.define(pnode.name, t);
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
        const is_imp = (d.value.* == .call and d.value.call.callee.* == .primary and std.mem.eql(u8, d.value.call.callee.primary.name, "@import"));
        if (is_imp or d.is_const) try top_consts.put(d.name, {});
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
        } else if (state.enums.contains(v)) {
            try env.globals.put(k, .{ .enum_ = v });
        } else if (state.structs.contains(v)) {
            try env.globals.put(k, .{ .struct_ = v });
        } else {
            try env.globals.put(k, try from_ast.parseDisplayType(state, ta, v, null));
        }
    }

    for (doc.statements) |s| {
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .type_decl, .extern_decl => continue,
            else => _ = try checkStmt(state, &env, ta, s),
        }
    }
}
