const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const from_ast = @import("from_ast.zig");
const ir = @import("ir.zig");
const path = @import("../expr/path.zig");
const intrinsics = @import("../intrinsics.zig");
const compiler_errors = @import("../../errors/compile.zig");
const widths = @import("../widths.zig");

pub const typeAstToDisplay = from_ast.typeAstToDisplay;

pub const TypecheckError = error{ OutOfMemory, CompileError, Overflow, InvalidCharacter };

pub const Env = struct {
    locals: std.ArrayList(std.StringHashMap(ir.Type)),
    globals: std.StringHashMap(ir.Type),
    expected_return: ?ir.Type = null,
    annotated_return: ?ir.Type = null,
    /// Const names visible outside any pushed scope (module level / function-wide).
    const_names: std.StringHashMap(void),
    /// Const names per lexical scope, parallel to `locals`. Block-local `@const`s
    /// live here so they are forgotten when the block exits.
    const_scopes: std.ArrayList(std.StringHashMap(void)),
    /// When set, literals keep singleton types (`"x"`, `0`, `true`) and arrays become deep tuples.
    prefer_literals: bool = false,
    /// True while typechecking a function body — locals must not overwrite `global_types`.
    in_function: bool = false,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Env {
        return .{
            .locals = .empty,
            .globals = std.StringHashMap(ir.Type).init(allocator),
            .const_names = std.StringHashMap(void).init(allocator),
            .const_scopes = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Env) void {
        for (self.locals.items) |*m| m.deinit();
        self.locals.deinit(self.allocator);
        self.globals.deinit();
        self.const_names.deinit();
        for (self.const_scopes.items) |*m| m.deinit();
        self.const_scopes.deinit(self.allocator);
    }

    fn pushScope(self: *Env) !void {
        try self.locals.append(self.allocator, std.StringHashMap(ir.Type).init(self.allocator));
        try self.const_scopes.append(self.allocator, std.StringHashMap(void).init(self.allocator));
    }

    fn popScope(self: *Env) void {
        if (self.locals.items.len == 0) return;
        var m = self.locals.pop().?;
        m.deinit();
        if (self.const_scopes.items.len > 0) {
            var c = self.const_scopes.pop().?;
            c.deinit();
        }
    }

    /// Record a `@const` name in the innermost scope (or the base set if none).
    fn putConstName(self: *Env, name: []const u8) !void {
        if (self.const_scopes.items.len > 0) {
            try self.const_scopes.items[self.const_scopes.items.len - 1].put(name, {});
        } else {
            try self.const_names.put(name, {});
        }
    }

    /// Whether `name` names a `@const` visible from the current scope.
    fn hasConstName(self: *const Env, name: []const u8) bool {
        var i = self.const_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.const_scopes.items[i].contains(name)) return true;
        }
        return self.const_names.contains(name);
    }

    pub fn define(self: *Env, name: []const u8, t: ir.Type) !void {
        if (self.locals.items.len > 0) {
            try self.locals.items[self.locals.items.len - 1].put(name, t);
        } else {
            try self.globals.put(name, t);
        }
    }

    pub fn lookup(self: *Env, name: []const u8) ?ir.Type {
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
    if (!state.strict and (ir.involvesUnknown(got) or ir.involvesUnknown(expected))) return;
    if (state.strict and ir.peelDefined(got) == .unknown and ir.peelDefined(expected) != .unknown) {
        const g = try ownDisplay(state, got);
        const e = try ownDisplay(state, expected);
        const file_path = if (loc.path.len > 0) loc.path else state.chunk.file;
        const line = if (loc.line > 0) loc.line else 1;
        const col = if (loc.column > 0) loc.column else 1;
        return compiler_errors.compileFailAt(
            state,
            file_path,
            sourceFor(state, file_path),
            line,
            col,
            "{s}: cannot assign opaque type '{s}' to '{s}'; explicit cast or narrowing required",
            .{ ctx, g, e },
        );
    }
    if (ir.isSubtype(got, expected)) {
        // When an untyped integer (int_lit) passes into a concrete integer context,
        // record the target type on the expression node so codegen emits the right
        // width rather than defaulting to i64.
        if (from) |node| {
            if (ir.peelDefined(got) == .int_lit and ir.widthOf(ir.peelDefined(expected)) != null) {
                try recordExprType(state, node, expected);
            }
        }
        return;
    }
    // int_lit as the expected type means a mutable variable whose type was inferred
    // from an integer literal without annotation (e.g. `$b = 20`).  Unlike its role
    // as a singleton in `@const` / switch patterns, here it acts as a "flexible
    // integer" and accepts reassignment from any concrete integer width silently.
    if (ir.peelDefined(expected) == .int_lit and ir.isInteger(ir.peelDefined(got))) {
        if (from) |node| try recordExprType(state, node, ir.TInt);
        return;
    }
    // Whole enum value → literal field only when RHS is that static variant.
    if (got == .enum_ and expected == .enum_lit) {
        if (std.mem.eql(u8, got.enum_, expected.enum_lit.enum_name)) {
            if (from) |node| {
                if (isEnumVariantValue(state, node, expected.enum_lit.enum_name, expected.enum_lit.variant)) return;
            }
        }
    }
    // Error set value → member lit / union arm when RHS is that static member.
    if (from) |node| {
        if (matchesErrorMemberToType(state, node, got, expected)) return;
    }
    // Value literal types / `@type` wrapping them (incl. unions of literals): matching literal RHS.
    if (from) |node| {
        if (matchesValueLiteralToType(node, expected)) return;
    }
    // Zig-style: integer literals may coerce into any integer width that fits.
    if (ir.isInteger(ir.peelDefined(expected)) and (got == .i64 or ir.peelDefined(got) == .int_lit)) {
        if (from) |node| {
            if (intLiteralFits(node, ir.widthOf(expected).?)) {
                try recordExprType(state, node, expected);
                return;
            } else if (isIntegerLiteral(node)) {
                const exp_name = try ownDisplay(state, expected);
                const file_path = if (loc.path.len > 0) loc.path else state.chunk.file;
                const line = if (loc.line > 0) loc.line else 1;
                const col = if (loc.column > 0) loc.column else 1;
                return compiler_errors.compileFailAt(
                    state,
                    file_path,
                    sourceFor(state, file_path),
                    line,
                    col,
                    "literal {s} overflows target type '{s}'",
                    .{ node.literal.value, exp_name },
                );
            }
        }
    }
    // Float literals are f64; may coerce into f32.
    if (ir.peelDefined(expected) == .f32 and got == .f64) {
        if (from) |node| {
            if (isFloatLiteral(node)) {
                try recordExprType(state, node, expected);
                return;
            }
        }
    }
    // String literals infer as []byte unless const, but may coerce into fixed [N]byte when length matches.
    if (from) |node| {
        if (node.* == .literal and node.literal.literal_type == .string) {
            const exp = ir.peelDefined(expected);
            if (exp == .array and exp.array.elem.* == .u8) {
                if (exp.array.length == null or exp.array.length.? == node.literal.value.len) {
                    try recordExprType(state, node, expected);
                    return;
                }
            }
        }
    }
    // Empty array literal `[]` contextually typed by expected array type
    if (from) |node| {
        if (node.* == .array_literal and node.array_literal.elements.len == 0) {
            const exp = ir.peelDefined(expected);
            if (exp == .array) {
                if (exp.array.length == null or exp.array.length.? == 0) {
                    try recordExprType(state, node, expected);
                    return;
                }
            }
        }
    }
    // Implicit numeric coercion: accept widening and narrowing within the
    // same signedness family, emitting a warning in both cases.
    // • Widening (i32→i64, u8→u32, f32→f64, int→float): lossless; soft warn.
    // • Narrowing (i64→i32, f64→f32, etc.): potentially lossy; stronger warn.
    // Cross-signedness (i32↔u32) and unrelated types remain hard errors.
    {
        const got_w = ir.widthOf(ir.peelDefined(got));
        const exp_w = ir.widthOf(ir.peelDefined(expected));
        if (got_w != null and exp_w != null) {
            const file_path = if (loc.path.len > 0) loc.path else state.chunk.file;
            const line = if (loc.line > 0) loc.line else 1;
            const col = if (loc.column > 0) loc.column else 1;
            const g = try ownDisplay(state, got);
            const e = try ownDisplay(state, expected);
            if (widths.isWidening(got_w.?, exp_w.?)) {
                compiler_errors.compileWarnAt(
                    state,
                    file_path,
                    sourceFor(state, file_path),
                    line,
                    col,
                    "{s}: implicit widening from '{s}' to '{s}' (use @as to silence)",
                    .{ ctx, g, e },
                );
                if (from) |node| try recordExprType(state, node, expected);
                return;
            }
            if (widths.isNarrowing(got_w.?, exp_w.?)) {
                if (state.strict) {
                    return compiler_errors.compileFailAt(
                        state,
                        file_path,
                        sourceFor(state, file_path),
                        line,
                        col,
                        "{s}: implicit narrowing from '{s}' to '{s}' rejected in strict mode (use @as to convert)",
                        .{ ctx, g, e },
                    );
                }
                compiler_errors.compileWarnAt(
                    state,
                    file_path,
                    sourceFor(state, file_path),
                    line,
                    col,
                    "{s}: implicit narrowing from '{s}' to '{s}' — possible data loss (use @as to silence)",
                    .{ ctx, g, e },
                );
                if (from) |node| try recordExprType(state, node, expected);
                return;
            }
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
                .number => parseNumWithUnderscores(i64, lit.value, 10) orelse break :blk false,
                .hex => parseNumWithUnderscores(i64, lit.value[2..], 16) orelse break :blk false,
                .octal => parseNumWithUnderscores(i64, lit.value[2..], 8) orelse break :blk false,
                .binary => parseNumWithUnderscores(i64, lit.value[2..], 2) orelse break :blk false,
                else => break :blk false,
            };
            break :blk n == expected.int_lit;
        },
        else => false,
    };
}

fn parseNumWithUnderscores(comptime T: type, raw: []const u8, radix: u8) ?T {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return null;
        buf[len] = c;
        len += 1;
    }
    return std.fmt.parseInt(T, buf[0..len], radix) catch null;
}

fn isIntegerLiteral(node: *ast.Node) bool {
    if (node.* != .literal) return false;
    return switch (node.literal.literal_type) {
        .number => std.mem.indexOfScalar(u8, node.literal.value, '.') == null and
            std.mem.indexOfScalar(u8, node.literal.value, 'e') == null and
            std.mem.indexOfScalar(u8, node.literal.value, 'E') == null,
        .hex, .octal, .binary => true,
        else => false,
    };
}

fn intLiteralFits(node: *ast.Node, width: widths.Width) bool {
    if (node.* != .literal) return false;
    const lit = node.literal;
    const n: i64 = switch (lit.literal_type) {
        .number => blk: {
            if (std.mem.indexOfScalar(u8, lit.value, '.') != null) return false;
            break :blk parseNumWithUnderscores(i64, lit.value, 10) orelse return false;
        },
        .hex => parseNumWithUnderscores(i64, lit.value[2..], 16) orelse return false,
        .octal => parseNumWithUnderscores(i64, lit.value[2..], 8) orelse return false,
        .binary => parseNumWithUnderscores(i64, lit.value[2..], 2) orelse return false,
        else => return false,
    };
    return widths.i64Fits(width, n);
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

fn isErrorMemberValue(state: *state_mod.CompilerState, node: *ast.Node, set_name: []const u8, variant: []const u8) bool {
    if (node.* != .member) return false;
    const mem = node.member;
    if (mem.property.* != .primary) return false;
    if (!std.mem.eql(u8, mem.property.primary.name, variant)) return false;
    const esname = from_ast.resolveErrorSetName(state, mem.object) orelse return false;
    return std.mem.eql(u8, esname, set_name);
}

fn matchesErrorMemberToType(state: *state_mod.CompilerState, node: *ast.Node, got: ir.Type, expected: ir.Type) bool {
    if (got != .error_set) return false;
    const exp = ir.peelDefined(expected);
    if (exp == .error_lit) {
        if (!std.mem.eql(u8, got.error_set, exp.error_lit.set_name)) return false;
        return isErrorMemberValue(state, node, exp.error_lit.set_name, exp.error_lit.variant);
    }
    if (exp == .union_) {
        for (exp.union_) |arm| {
            if (matchesErrorMemberToType(state, node, got, arm)) return true;
        }
    }
    return false;
}

fn isNumericType(t: ir.Type) bool {
    return ir.isNumeric(t);
}

/// Same-width numeric ops only (no implicit int↔float or f32↔f64).
/// Singleton int/bool literals widen to i64/u1 for operators.
fn requireNumericPair(state: *state_mod.CompilerState, l: ir.Type, r: ir.Type, ctx: []const u8) TypecheckError!ir.Type {
    const lw = numericOpType(l);
    const rw = numericOpType(r);
    if (!isNumericType(lw) or !isNumericType(rw)) {
        const dl = try ownDisplay(state, l);
        const dr = try ownDisplay(state, r);
        return compiler_errors.compileFailFmt(state, "{s}: expected matching numeric types, got '{s}' and '{s}'", .{ ctx, dl, dr });
    }
    if (!ir.typeEquals(lw, rw)) {
        const lw_w = ir.widthOf(lw);
        const rw_w = ir.widthOf(rw);
        if (lw_w != null and rw_w != null) {
            const wider: ?ir.Type = if (widths.isWidening(lw_w.?, rw_w.?))
                rw
            else if (widths.isWidening(rw_w.?, lw_w.?))
                lw
            else
                null;
            if (wider) |result_type| {
                const dl = try ownDisplay(state, l);
                const dr = try ownDisplay(state, r);
                const dres = try ownDisplay(state, result_type);
                compiler_errors.compileWarnFmt(
                    state,
                    "{s}: mixed '{s}' and '{s}' — widening to '{s}' (use @as to silence)",
                    .{ ctx, dl, dr, dres },
                );
                return result_type;
            }
        }
        const dl = try ownDisplay(state, l);
        const dr = try ownDisplay(state, r);
        return compiler_errors.compileFailFmt(state, "{s}: mixed '{s}' and '{s}' (use @as)", .{ ctx, dl, dr });
    }
    return lw;
}

fn numericOpType(t: ir.Type) ir.Type {
    return switch (ir.peelDefined(t)) {
        .int_lit => ir.TInt,
        .bool_lit => ir.TBool,
        else => |p| p,
    };
}

fn isPureLiteralExpr(node: *ast.Node) bool {
    return switch (node.*) {
        .literal => true,
        .array_literal => |a| blk: {
            for (a.elements) |el| {
                if (!isPureLiteralExpr(el)) break :blk false;
            }
            break :blk true;
        },
        .unary => |u| std.mem.eql(u8, u.operator, "const") and isPureLiteralExpr(u.arg),
        .struct_init => |init| blk: {
            for (init.fields) |f| {
                if (!isPureLiteralExpr(f.value)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn inferLiteral(ta: ir.TypeAlloc, lit: ast.Literal, prefer_literals: bool) !ir.Type {
    return switch (lit.literal_type) {
        .string => blk: {
            if (prefer_literals) break :blk .{ .str_lit = lit.value };
            break :blk try ta.arrayType(ir.TByte, null);
        },
        .boolean => blk: {
            if (prefer_literals) break :blk .{ .bool_lit = std.mem.eql(u8, lit.value, "true") };
            break :blk ir.TBool;
        },
        .null => ir.TNull,
        .number => blk: {
            if (std.mem.indexOfScalar(u8, lit.value, '.') != null or
                std.mem.indexOfScalar(u8, lit.value, 'e') != null or
                std.mem.indexOfScalar(u8, lit.value, 'E') != null)
            {
                break :blk ir.TF64;
            }
            // Integer literals are always untyped (int_lit) so they silently
            // coerce to whatever integer width their context demands, just like
            // Zig's comptime_int.  The concrete width is resolved at point of use.
            if (prefer_literals) {
                if (std.fmt.parseInt(i64, lit.value, 10)) |n| break :blk .{ .int_lit = n } else |_| {}
            }
            break :blk ir.TInt;
        },
        .hex, .octal, .binary => blk: {
            const n: i64 = switch (lit.literal_type) {
                .hex => std.fmt.parseInt(i64, lit.value[2..], 16) catch break :blk ir.TInt,
                .octal => std.fmt.parseInt(i64, lit.value[2..], 8) catch break :blk ir.TInt,
                .binary => std.fmt.parseInt(i64, lit.value[2..], 2) catch break :blk ir.TInt,
                else => unreachable,
            };
            if (prefer_literals) break :blk .{ .int_lit = n };
            break :blk ir.TInt;
        },
    };
}

fn fieldTypeFromStruct(state: *state_mod.CompilerState, ta: ir.TypeAlloc, struct_name: []const u8, field: []const u8) !ir.Type {
    const def = from_ast.lookupStruct(state, struct_name) orelse return ir.TUnknown;
    const raw = def.types.get(field) orelse return ir.TUnknown;
    return try from_ast.parseDisplayType(state, ta, raw, null);
}

fn lookupModuleDeclExact(state: *state_mod.CompilerState, ta: ir.TypeAlloc, mod_path: []const u8, member: []const u8) !?ir.Type {
    var sbuf: [512]u8 = undefined;
    const sub_key = std.fmt.bufPrint(&sbuf, "${s}::{s}", .{ mod_path, member }) catch return null;
    if (state.global_types.get(sub_key)) |gt| {
        if (std.mem.startsWith(u8, gt, "module:")) return ir.Type{ .struct_ = gt };
    }
    var bbuf: [512]u8 = undefined;
    const bare_sub_key = std.fmt.bufPrint(&bbuf, "${s}", .{member}) catch "";
    if (bare_sub_key.len > 0) {
        if (state.global_types.get(bare_sub_key)) |gt| {
            if (std.mem.startsWith(u8, gt, "module:")) return ir.Type{ .struct_ = gt };
        }
    }

    var qbuf: [512]u8 = undefined;
    const q = std.fmt.bufPrint(&qbuf, "{s}::{s}", .{ mod_path, member }) catch return null;
    if (state.chunk.exports.contains(q) or state.global_vars.contains(q) or state.global_consts.contains(q)) {
        if (state.global_types.get(q)) |gt| {
            if (std.mem.startsWith(u8, gt, "module:")) return ir.Type{ .struct_ = gt };
            return try from_ast.parseDisplayType(state, ta, gt, null);
        }
        if (try funcTypeOfName(state, ta, q)) |ft| return ft;
        if (state.structs.contains(q)) return ir.Type{ .struct_ = q };
        if (state.enums.contains(q)) return ir.Type{ .enum_ = q };
        if (state.error_sets.contains(q)) return ir.Type{ .error_set = q };
        if (state.typedefs.get(q)) |td| return try from_ast.parseDisplayType(state, ta, td.underlying, null);
        return ir.TUnknown;
    }
    if (state.global_types.get(q)) |gt| {
        if (std.mem.startsWith(u8, gt, "module:")) return ir.Type{ .struct_ = gt };
        return try from_ast.parseDisplayType(state, ta, gt, null);
    }
    if (try funcTypeOfName(state, ta, q)) |ft| return ft;
    if (state.structs.contains(q)) return ir.Type{ .struct_ = q };
    if (state.enums.contains(q)) return ir.Type{ .enum_ = q };
    if (state.error_sets.contains(q)) return ir.Type{ .error_set = q };
    if (state.typedefs.get(q)) |td| return try from_ast.parseDisplayType(state, ta, td.underlying, null);
    if (state.native_globals.contains(member)) return ir.TUnknown;
    return null;
}

fn resolveModuleMemberType(state: *state_mod.CompilerState, ta: ir.TypeAlloc, mod_path: []const u8, member: []const u8) !?ir.Type {
    if (try lookupModuleDeclExact(state, ta, mod_path, member)) |t| return t;
    if (std.mem.endsWith(u8, mod_path, ".lls")) {
        const no_ext = mod_path[0 .. mod_path.len - 4];
        if (try lookupModuleDeclExact(state, ta, no_ext, member)) |t| return t;
    } else {
        var mext: [512]u8 = undefined;
        const with_ext = std.fmt.bufPrint(&mext, "{s}.lls", .{mod_path}) catch return null;
        if (try lookupModuleDeclExact(state, ta, with_ext, member)) |t| return t;
    }
    return null;
}

const UnionFieldInfo = struct {
    /// Type of the field when it exists on every arm (a union when arms differ).
    ty: ir.Type,
    /// Set when the field is present on every arm but with *incompatible* types —
    /// the Common Property Rule is violated (Phase 3.2).
    conflict: bool,
};

/// Field type on a struct union. Discriminant `kind` with enum literals → parent enum.
fn fieldTypeFromUnion(state: *state_mod.CompilerState, ta: ir.TypeAlloc, union_t: ir.Type, field: []const u8) !UnionFieldInfo {
    if (union_t != .union_) return .{ .ty = ir.TUnknown, .conflict = false };
    var field_types: std.ArrayList(ir.Type) = .empty;
    defer field_types.deinit(ta.allocator);
    var enum_parent: ?[]const u8 = null;
    var all_kind_lits = std.mem.eql(u8, field, "kind");

    for (union_t.union_) |arm| {
        const sname = ir.structNameOf(arm) orelse return .{ .ty = ir.TUnknown, .conflict = false };
        const def = from_ast.lookupStruct(state, sname) orelse return .{ .ty = ir.TUnknown, .conflict = false };
        if (def.types.get(field) == null) return .{ .ty = ir.TUnknown, .conflict = false };
        const ft = try fieldTypeFromStruct(state, ta, sname, field);
        if (ft == .unknown) return .{ .ty = ir.TUnknown, .conflict = false };
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
    if (field_types.items.len == 0) return .{ .ty = ir.TUnknown, .conflict = false };
    if (all_kind_lits) {
        if (enum_parent) |ep| return .{ .ty = .{ .enum_ = ep }, .conflict = false };
    }
    // All equal → that type; otherwise the arms disagree (conflict).
    const first = field_types.items[0];
    for (field_types.items[1..]) |ft| {
        if (!ir.typeEquals(first, ft)) {
            return .{ .ty = try ta.unionType(field_types.items), .conflict = true };
        }
    }
    return .{ .ty = first, .conflict = false };
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

fn funcTypeOfName(state: *state_mod.CompilerState, ta: ir.TypeAlloc, func_name: []const u8) !?ir.Type {
    if (!state.functions.contains(func_name)) return null;
    var params: std.ArrayList(ir.Type) = .empty;
    defer params.deinit(ta.allocator);
    var rest: ?ir.Type = null;
    var variadic = false;
    if (!try fnParamTypes(state, ta, func_name, &params, &rest, &variadic)) return null;
    const ret = try fnReturnType(state, ta, func_name);
    return try ta.funcType(params.items, ret, variadic);
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
    const sd = from_ast.lookupStruct(state, sname) orelse return null;
    if (sd.offsets.contains(prop)) return null; // field, not method
    const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ sd.name, prop });
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
        } else if (state.strict) {
            const is_method_self = (method_struct != null and i == 0 and std.mem.eql(u8, pnode.name, "self"));
            if (!is_method_self) {
                return compiler_errors.compileFailFmt(state, "parameter '{s}' of function '{s}' must have an explicit type annotation in strict mode; write '{s}: int' (or the intended type)", .{ pnode.name, f.name, pnode.name });
            }
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

pub fn recordExprType(state: *state_mod.CompilerState, node: *ast.Node, t: ir.Type) !void {
    const codegen_t: ir.Type = switch (t) {
        .int_lit => ir.TInt,
        .bool_lit => ir.TBool,
        .str_lit => ir.TString,
        else => t,
    };
    // Never poison `type_of_results` with `unknown`: emit-time resolveType runs
    // after return-type refinement, so it can see through forward-referenced
    // unannotated functions. Recording `unknown` here would shadow that better
    // answer and degrade field access to dynamic GET_PROPERTY.
    if (codegen_t == .unknown) return;
    const disp = try ownDisplay(state, codegen_t);
    if (!state.type_of_results.contains(node)) {
        try state.type_of_results.put(node, disp);
    }
}

fn isBareIntLiteral(node: *ast.Node) bool {
    if (node.* != .literal) return false;
    return switch (node.literal.literal_type) {
        .number, .hex, .octal, .binary => true,
        else => false,
    };
}

/// Zig-style: a bare integer literal may take on the other operand's integer width.
fn coerceNumericPair(
    state: *state_mod.CompilerState,
    l: ir.Type,
    r: ir.Type,
    left_node: *ast.Node,
    right_node: *ast.Node,
    ctx: []const u8,
) TypecheckError!ir.Type {
    const lw = numericOpType(l);
    const rw = numericOpType(r);
    if (!isNumericType(lw) or !isNumericType(rw)) {
        const dl = try ownDisplay(state, l);
        const dr = try ownDisplay(state, r);
        return compiler_errors.compileFailFmt(state, "{s}: expected matching numeric types, got '{s}' and '{s}'", .{ ctx, dl, dr });
    }
    if (ir.typeEquals(lw, rw)) return lw;
    // Untyped integer variables (`int_lit` type from unannotated literal declarations
    // like `$a = 10`) adapt silently to the concrete type of the other operand —
    // just like a bare literal node does, but via the stored type rather than AST.
    const left_is_untyped = ir.peelDefined(l) == .int_lit;
    const right_is_untyped = ir.peelDefined(r) == .int_lit;
    if (left_is_untyped and !right_is_untyped) {
        try recordExprType(state, left_node, rw);
        return rw;
    }
    if (right_is_untyped and !left_is_untyped) {
        try recordExprType(state, right_node, lw);
        return lw;
    }
    if (lw == .f64 and isBareIntLiteral(right_node)) {
        try recordExprType(state, right_node, lw);
        return lw;
    }
    if (rw == .f64 and isBareIntLiteral(left_node)) {
        try recordExprType(state, left_node, rw);
        return rw;
    }
    if (ir.isInteger(lw) and ir.isInteger(rw)) {
        // Both untyped OR both typed with same i64 width: fall through.
        // Existing bare-literal coercion (lw == .i64 and isBareIntLiteral) below.
        if (lw == .i64 and isBareIntLiteral(left_node) and rw != .i64) {
            try recordExprType(state, left_node, rw);
            return rw;
        }
        if (rw == .i64 and isBareIntLiteral(right_node) and lw != .i64) {
            try recordExprType(state, right_node, lw);
            return lw;
        }
    }
    // Implicit numeric coercion for binary operators: if both operands are in
    // the same integer/float signedness family, widen the narrower one and
    // warn.  The result type is the wider of the two.
    {
        const lw_w = ir.widthOf(lw);
        const rw_w = ir.widthOf(rw);
        if (lw_w != null and rw_w != null) {
            const wider: ?ir.Type = if (widths.isWidening(lw_w.?, rw_w.?))
                rw // rw is wider
            else if (widths.isWidening(rw_w.?, lw_w.?))
                lw // lw is wider
            else
                null;
            if (wider) |result_type| {
                const dl = try ownDisplay(state, l);
                const dr = try ownDisplay(state, r);
                const dres = try ownDisplay(state, result_type);
                return compiler_errors.compileFailFmt(
                    state,
                    "{s}: mixed '{s}' and '{s}' — widening to '{s}' (use @as)",
                    .{ ctx, dl, dr, dres },
                );
            }
        }
    }
    const dl = try ownDisplay(state, l);
    const dr = try ownDisplay(state, r);
    return compiler_errors.compileFailFmt(state, "{s}: mixed '{s}' and '{s}' (use @as)", .{ ctx, dl, dr });
}

pub fn inferExpr(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    noteDiag(state, node);
    const result = try inferExprInner(state, env, ta, node);
    try recordExprType(state, node, result);
    return result;
}

fn inferExprInner(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    return switch (node.*) {
        .literal => |lit| try inferLiteral(ta, lit, env.prefer_literals),
        .primary => |p| blk: {
            if (p.kind == .identifier or p.kind == .register) {
                if (env.lookup(p.name)) |t| break :blk t;
                if (state.global_types.get(p.name)) |gt| {
                    if (std.mem.startsWith(u8, gt, "module:")) {
                        break :blk .{ .struct_ = gt };
                    }
                    break :blk try from_ast.parseDisplayType(state, ta, gt, null);
                }
                if (try funcTypeOfName(state, ta, p.name)) |ft| break :blk ft;
            }
            break :blk ir.TUnknown;
        },
        .unary => |u| blk: {
            if (std.mem.eql(u8, u.operator, "const")) {
                const prev = env.prefer_literals;
                env.prefer_literals = true;
                defer env.prefer_literals = prev;
                break :blk try inferExpr(state, env, ta, u.arg);
            }
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
                        // Ordered comparisons allow mixed numeric widths with a
                        // warning (runtime widens via f64). Arithmetic stays strict.
                        _ = try requireNumericPair(state, l, r, "comparison");
                    }
                }
                break :blk ir.TBool;
            }
            if (std.mem.eql(u8, op, "+")) {
                if (ir.isByteSlice(l) or ir.isByteSlice(r)) break :blk ir.TString;
                if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                    break :blk try coerceNumericPair(state, l, r, b.left, b.right, "numeric +");
                }
                break :blk ir.TInt;
            }
            if (isArith(op)) {
                if (!ir.involvesUnknown(l) and !ir.involvesUnknown(r)) {
                    break :blk try coerceNumericPair(state, l, r, b.left, b.right, "operator");
                }
                break :blk ir.TInt;
            }
            break :blk ir.TUnknown;
        },
        .call => |*c| try inferCall(state, env, ta, node, c),
        .member => |m| blk: {
            if (m.property.* == .primary) {
                if (from_ast.resolveErrorSetName(state, m.object)) |esname| {
                    if (state.error_sets.get(esname)) |ed| {
                        if (!ed.variants.contains(m.property.primary.name)) {
                            return compiler_errors.compileFailFmt(state, "Unknown error member '{s}' on '{s}'", .{ m.property.primary.name, esname });
                        }
                        // Value `Set.Member` has parent set type (like enums).
                        break :blk .{ .error_set = esname };
                    }
                }
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
            if (state.strict and ir.optionalPayload(obj) != null) {
                const d = try ownDisplay(state, obj);
                return compiler_errors.compileFailFmt(
                    state,
                    "cannot access field '{s}' on optional type '{s}'; unwrap with '@if' or '.?'",
                    .{ m.property.primary.name, d },
                );
            }
            if (m.property.* == .primary) {
                // Layout key first — `@type Name = {…}` registers under Name.
                if (ir.structNameOf(obj)) |sname| {
                    if (std.mem.startsWith(u8, sname, "module:")) {
                        const mod_path = sname["module:".len..];
                        if (try resolveModuleMemberType(state, ta, mod_path, m.property.primary.name)) |mt| {
                            break :blk mt;
                        }
                        const mod_display = if (m.object.* == .primary) m.object.primary.name else mod_path;
                        return compiler_errors.compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_display, m.property.primary.name });
                    }
                    if (from_ast.lookupStruct(state, sname)) |def| {
                        if (def.types.get(m.property.primary.name) == null) {
                            return compiler_errors.compileFailFmt(state, "Field '{s}' does not exist on '{s}'", .{ m.property.primary.name, ir.cleanTypeName(sname) });
                        }
                    }
                    break :blk try fieldTypeFromStruct(state, ta, sname, m.property.primary.name);
                }
                if (path.tryResolveStaticPath(state, m.object) catch null) |sp| {
                    var is_mod = false;
                    if (from_ast.resolveType(state, m.object)) |t| {
                        if (std.mem.startsWith(u8, t, "module:")) is_mod = true;
                    }
                    if (is_mod) {
                        if (try resolveModuleMemberType(state, ta, sp, m.property.primary.name)) |mt| {
                            break :blk mt;
                        }
                        const mod_display = if (m.object.* == .primary) m.object.primary.name else sp;
                        return compiler_errors.compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_display, m.property.primary.name });
                    }
                }
                const field_obj = ir.peelDefined(obj);
                // Tuple / array numeric field access: `.0`, `.1`, …
                if (field_obj == .tuple) {
                    if (std.fmt.parseInt(i64, m.property.primary.name, 10)) |ci| {
                        if (ci < 0 or ci >= field_obj.tuple.len) {
                            return compiler_errors.compileFailFmt(state, "Tuple field .{s} out of range (len {d})", .{ m.property.primary.name, field_obj.tuple.len });
                        }
                        break :blk field_obj.tuple[@intCast(ci)];
                    } else |_| {
                        return compiler_errors.compileFailFmt(state, "Tuple fields are numeric (.0, .1, …), got '.{s}'", .{m.property.primary.name});
                    }
                }
                if (field_obj == .array) {
                    if (std.fmt.parseInt(i64, m.property.primary.name, 10) catch null) |ci| {
                        if (field_obj.array.length) |alen| {
                            if (ci < 0 or ci >= @as(i64, @intCast(alen))) {
                                return compiler_errors.compileFailFmt(state, "Tuple field .{s} out of range (len {d})", .{ m.property.primary.name, alen });
                            }
                        }
                        break :blk field_obj.array.elem.*;
                    }
                }
                if (field_obj == .shape) {
                    for (field_obj.shape) |sf| {
                        if (std.mem.eql(u8, sf.name, m.property.primary.name)) break :blk sf.ty;
                    }
                    const d = try ownDisplay(state, field_obj);
                    return compiler_errors.compileFailFmt(state, "Field '{s}' does not exist on '{s}'", .{ m.property.primary.name, d });
                }
                if (field_obj == .union_) {
                    const info = try fieldTypeFromUnion(state, ta, field_obj, m.property.primary.name);
                    const ft = info.ty;
                    // Hard reject only for discrim struct unions (`Literal | Add`).
                    // Error unions (`T | error`) still allow gradual field access.
                    if (ft == .unknown) {
                        const d = try ownDisplay(state, field_obj);
                        if (try from_ast.discrimVariantMap(state, state.allocator, d)) |info_owned| {
                            var info2 = info_owned;
                            info2.map.deinit();
                            return compiler_errors.compileFailFmt(state, "Field '{s}' is not available on all arms of '{s}' (narrow with @switch on .kind)", .{ m.property.primary.name, d });
                        }
                        if (state.strict) {
                            return compiler_errors.compileFailFmt(state, "Field '{s}' is not available on union type '{s}'", .{ m.property.primary.name, d });
                        }
                    }
                    // Common Property Rule (Phase 3.2): every arm defines the field,
                    // but the types disagree — reject rather than silently union them.
                    if (info.conflict and state.strict) {
                        const d = try ownDisplay(state, field_obj);
                        return compiler_errors.compileFailFmt(state, "Field '{s}' has incompatible types across arms of union '{s}'; narrow with @switch on .kind or use @as", .{ m.property.primary.name, d });
                    }
                    break :blk ft;
                }
                if (state.strict and field_obj != .unknown and ir.structNameOf(obj) == null and field_obj != .tuple and field_obj != .shape) {
                    const d = try ownDisplay(state, obj);
                    return compiler_errors.compileFailFmt(state, "cannot access field '{s}' on type '{s}'", .{ m.property.primary.name, d });
                }
            }
            if (state.strict and obj != .unknown) {
                const d = try ownDisplay(state, obj);
                return compiler_errors.compileFailFmt(state, "cannot access property on type '{s}'", .{d});
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
            if (obj == .tuple) {
                if (try constIntIndex(idx.index.?)) |ci| {
                    if (ci < 0 or ci >= obj.tuple.len) {
                        return compiler_errors.compileFailFmt(state, "Tuple index {d} out of range (len {d})", .{ ci, obj.tuple.len });
                    }
                    break :blk obj.tuple[@intCast(ci)];
                }
                // Non-constant index: gradual
                break :blk ir.TUnknown;
            }
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
                if (mem.object.* == .primary) {
                    const obj_name = mem.object.primary.name;
                    if (env.hasConstName(obj_name) or (obj_name.len > 0 and obj_name[0] == '$' and env.hasConstName(obj_name[1..]))) {
                        return compiler_errors.compileFailFmt(state, "Cannot mutate field of constant '{s}'", .{obj_name});
                    }
                }
                const obj = try inferExpr(state, env, ta, mem.object);
                if (mem.property.* == .primary) {
                    var field_obj = obj;
                    if (field_obj == .defined) field_obj = field_obj.defined.underlying.*;
                    if (field_obj == .tuple) {
                        if (std.fmt.parseInt(i64, mem.property.primary.name, 10)) |ci| {
                            if (ci < 0 or ci >= field_obj.tuple.len) {
                                return compiler_errors.compileFailFmt(state, "Tuple field .{s} out of range (len {d})", .{ mem.property.primary.name, field_obj.tuple.len });
                            }
                            try requireAssignFrom(state, val, field_obj.tuple[@intCast(ci)], "assignment to tuple field", a.right);
                        } else |_| {
                            return compiler_errors.compileFailFmt(state, "Tuple fields are numeric (.0, .1, …), got '.{s}'", .{mem.property.primary.name});
                        }
                    } else if (field_obj == .array) {
                        if (std.fmt.parseInt(i64, mem.property.primary.name, 10) catch null) |ci| {
                            if (field_obj.array.length) |alen| {
                                if (ci < 0 or ci >= @as(i64, @intCast(alen))) {
                                    return compiler_errors.compileFailFmt(state, "Tuple field .{s} out of range (len {d})", .{ mem.property.primary.name, alen });
                                }
                            }
                            try requireAssignFrom(state, val, field_obj.array.elem.*, "assignment to array element", a.right);
                        } else {
                            return compiler_errors.compileFailFmt(state, "Array fields are numeric (.0, .1, …), got '.{s}'", .{mem.property.primary.name});
                        }
                    } else if (ir.structNameOf(obj)) |sname| {
                        if (std.mem.startsWith(u8, sname, "module:")) {
                            const mod_path = sname["module:".len..];
                            // A module may write another module's exported *mutable*
                            // global (`internal.defaultOutput = bridge`); everything
                            // else reachable through the namespace is read-only.
                            if (path.moduleMemberIsMutableGlobal(state, mod_path, mem.property.primary.name)) {
                                if (try resolveModuleMemberType(state, ta, mod_path, mem.property.primary.name)) |mt| {
                                    try recordExprType(state, a.left, mt);
                                    try requireAssignFrom(state, val, mt, "assignment to field", a.right);
                                }
                                break :blk val;
                            }
                            return compiler_errors.compileFailFmt(
                                state,
                                "Cannot assign to member '{s}' of imported module '{s}'",
                                .{ mem.property.primary.name, mod_path },
                            );
                        }
                        if (from_ast.lookupStruct(state, sname)) |def| {
                            if (def.types.get(mem.property.primary.name) == null) {
                                return compiler_errors.compileFailFmt(
                                    state,
                                    "Field '{s}' does not exist on '{s}'",
                                    .{ mem.property.primary.name, ir.cleanTypeName(sname) },
                                );
                            }
                        }
                        const ft = try fieldTypeFromStruct(state, ta, sname, mem.property.primary.name);
                        // Record the field type on the member node so editor
                        // features (hover) can resolve assignment targets.
                        try recordExprType(state, a.left, ft);
                        try requireAssignFrom(state, val, ft, "assignment to field", a.right);
                    } else {
                        const mod_name = if (from_ast.resolveType(state, mem.object)) |rt|
                            (if (std.mem.startsWith(u8, rt, "module:")) rt["module:".len..] else null)
                        else if (path.tryResolveStaticPath(state, mem.object) catch null) |sp|
                            (if (from_ast.resolveType(state, mem.object)) |t| (if (std.mem.startsWith(u8, t, "module:")) sp else null) else null)
                        else
                            null;
                        if (mod_name) |mn| {
                            if (path.moduleMemberIsMutableGlobal(state, mn, mem.property.primary.name)) {
                                if (try resolveModuleMemberType(state, ta, mn, mem.property.primary.name)) |mt| {
                                    try recordExprType(state, a.left, mt);
                                    try requireAssignFrom(state, val, mt, "assignment to field", a.right);
                                }
                                break :blk val;
                            }
                            return compiler_errors.compileFailFmt(
                                state,
                                "Cannot assign to member '{s}' of imported module '{s}'",
                                .{ mem.property.primary.name, mn },
                            );
                        }
                        if (field_obj != .unknown) {
                            const d = try ownDisplay(state, obj);
                            return compiler_errors.compileFailFmt(state, "cannot assign field '{s}' on type '{s}'", .{ mem.property.primary.name, d });
                        }
                    }
                }
            } else if (a.left.* == .index) {
                if (a.left.index.is_slice) {
                    return compiler_errors.compileFailFmt(state, "Cannot assign to a slice view", .{});
                }
                if (a.left.index.object.* == .primary) {
                    const obj_name = a.left.index.object.primary.name;
                    if (env.hasConstName(obj_name) or (obj_name.len > 0 and obj_name[0] == '$' and env.hasConstName(obj_name[1..]))) {
                        return compiler_errors.compileFailFmt(state, "Cannot mutate elements of constant '{s}'", .{obj_name});
                    }
                }
                const obj_t = try inferExpr(state, env, ta, a.left.index.object);
                const start_node = a.left.index.index orelse {
                    return compiler_errors.compileFailFmt(state, "Expected index expression", .{});
                };
                const i = try inferExpr(state, env, ta, start_node);
                if (!ir.involvesUnknown(i)) try requireAssign(state, i, ir.TInt, "index");
                if (obj_t == .array) {
                    try requireAssignFrom(state, val, obj_t.array.elem.*, "assignment to index", a.right);
                } else if (obj_t == .tuple) {
                    if (try constIntIndex(start_node)) |ci| {
                        if (ci < 0 or ci >= obj_t.tuple.len) {
                            return compiler_errors.compileFailFmt(state, "Tuple index {d} out of range (len {d})", .{ ci, obj_t.tuple.len });
                        }
                        try requireAssignFrom(state, val, obj_t.tuple[@intCast(ci)], "assignment to tuple index", a.right);
                    }
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
            const cond_t = try inferExpr(state, env, ta, i.condition);
            try env.pushScope();
            defer env.popScope();
            // `@if (@isError(x))` — narrow `x` to `error` in the then-body so
            // `return x` typechecks against any error-union return.
            if (isErrorNarrowName(i.condition)) |ename| {
                try env.define(ename, ir.TError);
            }
            if (i.pipe_value) |pv| {
                if (pv.* != .primary) return compiler_errors.compileFailFmt(state, "if capture must be identifier", .{});
                const peeled = ir.peelDefined(cond_t);
                if (ir.optionalPayload(peeled)) |opt| {
                    try env.define(pv.primary.name, opt);
                } else if (ir.isErrorUnion(peeled)) {
                    const unwrapped = try ir.unwrapError(ta, peeled);
                    try env.define(pv.primary.name, unwrapped);
                } else if (state.strict) {
                    const disp = try ownDisplay(state, cond_t);
                    return compiler_errors.compileFailFmt(state, "cannot capture from non-container type '{s}'; @if capture requires optional '?T' or error union", .{disp});
                } else {
                    const unwrapped = cond_t;
                    try env.define(pv.primary.name, unwrapped);
                }
            } else if (state.strict) {
                if (!ir.isSubtype(ir.peelDefined(cond_t), ir.TBool)) {
                    const disp = try ownDisplay(state, cond_t);
                    return compiler_errors.compileFailFmt(state, "condition of @if must be boolean ('bool' or 'u1'), got '{s}'; compare explicitly (e.g. 'x != 0') for a truthiness test", .{disp});
                }
            }
            _ = try inferExpr(state, env, ta, i.body);
            if (i.else_body) |e| _ = try inferExpr(state, env, ta, e);
            // Value-producing if (has else) joins break payloads.
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
                try walkBreakValues(state, env, ta, prong.body, &acc, false);
            }
            break :blk acc orelse ir.TUnknown;
        },
        .for_expr => |f| blk: {
            const expr_type = try inferExpr(state, env, ta, f.expr);
            try env.pushScope();
            defer env.popScope();
            if (f.captures.len > 0) {
                if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..")) {
                    if (f.captures.len > 1) return compiler_errors.compileFailFmt(state, "Range loop only supports 1 capture", .{});
                    for (f.captures) |cap| try env.define(cap.name, ir.TInt);
                } else if (ir.isByteSlice(expr_type) or expr_type == .array or ir.isString(expr_type)) {
                    if (f.captures.len > 2) return compiler_errors.compileFailFmt(state, "Loop supports at most 2 captures", .{});
                    const elem_type = if (expr_type == .array) expr_type.array.elem.* else ir.TU8;
                    try env.define(f.captures[0].name, elem_type);
                    if (f.captures.len > 1) {
                        try env.define(f.captures[1].name, ir.TInt);
                    }
                } else if (ir.involvesUnknown(expr_type)) {
                    // It might be a loop over an unknown optional payload or unknown array.
                    // We assume it's valid and bind `unknown`.
                    if (f.captures.len > 2) return compiler_errors.compileFailFmt(state, "Loop supports at most 2 captures", .{});
                    if (f.captures.len > 0) try env.define(f.captures[0].name, ir.TUnknown);
                    if (f.captures.len > 1) try env.define(f.captures[1].name, ir.TUnknown);
                } else if (ir.optionalPayload(expr_type)) |payload| {
                    if (f.captures.len > 1) return compiler_errors.compileFailFmt(state, "Optional while-loop only supports 1 capture", .{});
                    try state.for_is_cond.put(&node.for_expr, {});
                    try env.define(f.captures[0].name, payload);
                } else {
                    return compiler_errors.compileFailFmt(state, "Cannot iterate over type '{any}'", .{ir.typeTag(expr_type).?});
                }
            } else if (!(f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, ".."))) {
                // Condition loop `@for (cond) { … }` — same invariant as `@if`:
                // the condition must be a real boolean, no truthiness coercion.
                if (state.strict and !ir.isSubtype(ir.peelDefined(expr_type), ir.TBool)) {
                    const disp = try ownDisplay(state, expr_type);
                    return compiler_errors.compileFailFmt(state, "condition of @for must be boolean ('bool' or 'u1'), got '{s}'; compare explicitly (e.g. 'i < n')", .{disp});
                }
            }
            _ = try inferExpr(state, env, ta, f.body);
            break :blk ir.TUnknown;
        },
        .break_expr => |br| blk: {
            if (br.value) |v| break :blk try inferExpr(state, env, ta, v);
            break :blk ir.TUnknown;
        },
        .comptime_expr => |ce| blk: {
            // `@comptime` carries a real type: infer it structurally from the
            // inner expression using the typechecker's own knowledge. Evaluation
            // of the value itself happens once, in codegen (`compileComptime`), so
            // const values need not be materialized during the typecheck pass and
            // blocks may freely reference earlier `@const`s.
            //
            // A block is typed by running its local declarations through the
            // checker in a fresh scope and joining the types of its `break` values.
            if (ce.expr.* == .block) {
                try env.pushScope();
                defer env.popScope();
                for (ce.expr.block.statements) |s| _ = try checkStmt(state, env, ta, s);
                break :blk try joinComptimeTypes(state, env, ta, ce.expr);
            }
            break :blk try inferExpr(state, env, ta, ce.expr);
        },
        else => ir.TUnknown,
    };
}

fn joinBreakTypes(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    var acc: ?ir.Type = null;
    try walkBreakValues(state, env, ta, node, &acc, false);
    return acc orelse ir.TUnknown;
}

/// Like `joinBreakTypes`, but a `@comptime` block also yields its value via
/// `return`, so those payloads participate in the join too.
fn joinComptimeTypes(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node) TypecheckError!ir.Type {
    var acc: ?ir.Type = null;
    try walkBreakValues(state, env, ta, node, &acc, true);
    return acc orelse ir.TUnknown;
}

/// Merge a produced value type into the running `acc`, widening to `unknown` on
/// an irreconcilable conflict and to a union when one side is `null`.
fn mergeResultType(ta: ir.TypeAlloc, acc: *?ir.Type, t: ir.Type) !void {
    if (acc.*) |cur| {
        if (!ir.isSubtype(t, cur) and !ir.isSubtype(cur, t)) {
            if (!ir.involvesUnknown(t) and !ir.involvesUnknown(cur) and !ir.typeEquals(t, cur)) {
                if ((t == .null or cur == .null) and t != .union_ and cur != .union_) {
                    const u_arms = try ta.allocator.alloc(ir.Type, 2);
                    u_arms[0] = cur;
                    u_arms[1] = t;
                    acc.* = .{ .union_ = u_arms };
                } else {
                    acc.* = ir.TUnknown;
                }
            } else {
                acc.* = ir.TUnknown;
            }
        } else if (ir.isSubtype(cur, t)) {
            acc.* = t;
        }
    } else {
        acc.* = t;
    }
}

fn walkBreakValues(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, node: *ast.Node, acc: *?ir.Type, include_returns: bool) TypecheckError!void {
    switch (node.*) {
        .break_expr => |br| {
            if (br.value) |v| {
                try mergeResultType(ta, acc, try inferExpr(state, env, ta, v));
            }
        },
        .return_expr => |r| {
            if (include_returns) {
                if (r.return_value) |v| {
                    try mergeResultType(ta, acc, try inferExpr(state, env, ta, v));
                }
            }
        },
        .block => |b| {
            for (b.statements) |s| try walkBreakValues(state, env, ta, s, acc, include_returns);
        },
        .if_expr => |i| {
            try walkBreakValues(state, env, ta, i.body, acc, include_returns);
            if (i.else_body) |e| try walkBreakValues(state, env, ta, e, acc, include_returns);
        },
        .switch_expr => |sw| {
            for (sw.prongs) |p| try walkBreakValues(state, env, ta, p.body, acc, include_returns);
        },
        .for_expr => |f| try walkBreakValues(state, env, ta, f.body, acc, include_returns),
        .declaration => |d| try walkBreakValues(state, env, ta, d.value, acc, include_returns),
        else => {},
    }
}

fn isCmpOrLogic(op: []const u8) bool {
    return std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=") or
        std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "||");
}

/// `@if (@isError(name))` → `name` for then-branch narrowing to `error`.
fn isErrorNarrowName(cond: *ast.Node) ?[]const u8 {
    if (cond.* != .call) return null;
    const c = &cond.call;
    if (c.callee.* != .primary) return null;
    if (!std.mem.eql(u8, c.callee.primary.name, "@isError")) return null;
    if (c.args.len != 1) return null;
    if (c.args[0].* != .primary) return null;
    const p = c.args[0].primary;
    if (p.kind != .identifier and p.kind != .register) return null;
    return p.name;
}

fn isArith(op: []const u8) bool {
    return std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or
        std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%") or
        std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**") or
        // Wrapping arithmetic mirrors the checked operators' types exactly.
        std.mem.eql(u8, op, "+%") or std.mem.eql(u8, op, "-%") or std.mem.eql(u8, op, "*%");
}

fn inferCall(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, call_node: *ast.Node, c: *const ast.Call) TypecheckError!ir.Type {
    if (c.callee.* == .primary and std.mem.startsWith(u8, c.callee.primary.name, "@")) {
        const name = c.callee.primary.name;
        if (intrinsics.match(name)) |i| {
            return try intrinsics.typecheck(state, env, ta, i, call_node, c);
        }
        return compiler_errors.compileFailFmt(state, "unknown intrinsic '{s}'", .{name});
    }

    // `T(x)` cast sugar ≡ `@as(T, x)` when T is a type and not a function.
    if (try intrinsics.tryTypeCastCall(state, c)) |type_node| {
        return try intrinsics.typecheckCast(state, env, ta, type_node, c.args[0]);
    }

    // Native `len(x)` (arrays / strings / tuples) always yields an integer.
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "len") and
        !state.functions.contains("len"))
    {
        for (c.args) |a| _ = try inferExpr(state, env, ta, a);
        return ir.TInt;
    }

    // `arrayLike.get(i)` → `?T` (null when out of bounds) — Phase 4.4.
    if (c.callee.* == .member and c.callee.member.property.* == .primary and
        std.mem.eql(u8, c.callee.member.property.primary.name, "get") and c.args.len == 1)
    {
        const obj_ty = try inferExpr(state, env, ta, c.callee.member.object);
        _ = try inferExpr(state, env, ta, c.args[0]);
        const disp = try ownDisplay(state, obj_ty);
        if (arrayElemDisplay(disp)) |elem_disp| {
            const elem = ir.parseDisplayType(ta, elem_disp) catch ir.TUnknown;
            var arms = [_]ir.Type{ elem, ir.TNull };
            return try ta.unionType(&arms);
        }
    }

    const method = try resolveMethodCallee(state, env, ta, c);
    const name: ?[]const u8 = if (method) |m| m.name else resolveCalleeName(state, c);
    const named_fn = if (name) |n| state.functions.contains(n) else false;
    if (method != null or named_fn) {
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

    // First-class / typed function value: `$f(…)` where `$f: @func(…)`.
    const callee_ty = ir.peelDefined(try inferExpr(state, env, ta, c.callee));
    if (callee_ty == .func) {
        try checkFuncValueCall(state, env, ta, callee_ty, c);
        return callee_ty.func.ret.*;
    }
    for (c.args) |a| _ = try inferExpr(state, env, ta, a);
    return ir.TUnknown;
}

fn checkFuncValueCall(
    state: *state_mod.CompilerState,
    env: *Env,
    ta: ir.TypeAlloc,
    fn_ty: ir.Type,
    c: *const ast.Call,
) TypecheckError!void {
    const f = fn_ty.func;
    const named_count = f.params.len;
    const any_annotated = blk: {
        for (f.params) |p| {
            if (p != .unknown) break :blk true;
        }
        break :blk false;
    };
    if (!f.variadic and any_annotated and c.args.len != named_count) {
        const d = try ownDisplay(state, fn_ty);
        return compiler_errors.compileFailFmt(state, "Function value '{s}' expected {d} arguments, got {d}", .{ d, named_count, c.args.len });
    }
    const ncheck = @min(c.args.len, named_count);
    var i: usize = 0;
    while (i < ncheck) : (i += 1) {
        const at = try inferExpr(state, env, ta, c.args[i]);
        var ctx_buf: [96]u8 = undefined;
        const ctx = std.fmt.bufPrint(&ctx_buf, "argument {d}", .{i + 1}) catch "argument";
        try requireAssignFrom(state, at, f.params[i], ctx, c.args[i]);
    }
    while (i < c.args.len) : (i += 1) {
        _ = try inferExpr(state, env, ta, c.args[i]);
    }
}

/// For an array/slice display type (`[N]T`, `[]T`), return the element display
/// string. Returns null for tuples (`[A, B]`) and non-array types.
fn arrayElemDisplay(disp: []const u8) ?[]const u8 {
    if (disp.len < 2 or disp[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, disp, ']') orelse return null;
    const rest = std.mem.trim(u8, disp[close + 1 ..], " \t");
    if (rest.len == 0) return null;
    return rest;
}

fn constIntIndex(node: *ast.Node) !?i64 {
    if (node.* != .literal) return null;
    const lit = node.literal;
    return switch (lit.literal_type) {
        .number => std.fmt.parseInt(i64, lit.value, 10) catch null,
        .hex => std.fmt.parseInt(i64, lit.value[2..], 16) catch null,
        .octal => std.fmt.parseInt(i64, lit.value[2..], 8) catch null,
        .binary => std.fmt.parseInt(i64, lit.value[2..], 2) catch null,
        else => null,
    };
}

fn inferArrayLiteral(state: *state_mod.CompilerState, env: *Env, ta: ir.TypeAlloc, a: ast.ArrayLiteral) TypecheckError!ir.Type {
    if (a.elements.len == 0) return try ta.arrayType(ir.TUnknown, 0);
    var types: std.ArrayList(ir.Type) = .empty;
    defer types.deinit(ta.allocator);
    for (a.elements) |el| {
        try types.append(ta.allocator, try inferExpr(state, env, ta, el));
    }

    // `const […]` — always a deep tuple of element types (TS `as const` style).
    if (env.prefer_literals) return try ta.tupleType(types.items);

    // Homogeneous → fixed array; otherwise heterogeneous tuple.
    var elem = types.items[0];
    var homogeneous = true;
    var i: usize = 1;
    while (i < types.items.len) : (i += 1) {
        const ti = types.items[i];
        if (ir.involvesUnknown(elem) or ir.involvesUnknown(ti)) {
            if (elem == .unknown) elem = ti;
            continue;
        }
        if (elem == .array and ti == .array) {
            if (elem.array.length != null and ti.array.length != null and elem.array.length.? != ti.array.length.?) {
                homogeneous = false;
                break;
            }
            if (!ir.isSubtype(ti.array.elem.*, elem.array.elem.*) and !ir.isSubtype(elem.array.elem.*, ti.array.elem.*)) {
                homogeneous = false;
                break;
            }
            const len = if (elem.array.length != null) elem.array.length else ti.array.length;
            const inner = if (ir.isSubtype(ti.array.elem.*, elem.array.elem.*)) elem.array.elem.* else ti.array.elem.*;
            elem = try ta.arrayType(inner, len);
            continue;
        }
        if (!ir.isSubtype(ti, elem) and !ir.isSubtype(elem, ti)) {
            homogeneous = false;
            break;
        }
        if (!ir.isSubtype(ti, elem)) elem = ti;
    }
    if (homogeneous) return try ta.arrayType(elem, a.elements.len);
    return try ta.tupleType(types.items);
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

    const is_typedef = state.typedefs.contains(struct_name);
    if (!state.structs.contains(struct_name) and !is_typedef) {
        return compiler_errors.compileFailFmt(state, "Unknown struct '{s}'", .{sn});
    }
    if (is_typedef and !state.structs.contains(struct_name)) {
        return compiler_errors.compileFailFmt(state, "Type '{s}' is not an object shape (cannot initialize with '{{…}}')", .{sn});
    }

    for (init.fields) |field| {
        const expected = try fieldTypeFromStruct(state, ta, struct_name, field.name);
        if (expected == .unknown) {
            if (from_ast.lookupStruct(state, struct_name)) |def| {
                if (def.types.get(field.name) == null) {
                    return compiler_errors.compileFailFmt(state, "Unknown field '{s}' on '{s}'", .{ field.name, ir.cleanTypeName(struct_name) });
                }
            }
        }
        const got = try inferExpr(state, env, ta, field.value);
        var ctx_buf: [128]u8 = undefined;
        const ctx = std.fmt.bufPrint(&ctx_buf, "field '{s}' of '{s}'", .{ field.name, ir.cleanTypeName(struct_name) }) catch "field";
        try requireAssignFrom(state, got, expected, ctx, field.value);
    }
    if (state.strict) {
        if (from_ast.lookupStruct(state, struct_name)) |def| {
            var it = def.types.iterator();
            while (it.next()) |entry| {
                const required_name = entry.key_ptr.*;
                const field_type_name = entry.value_ptr.*;
                const is_optional = std.mem.startsWith(u8, field_type_name, "?") or
                    std.mem.indexOf(u8, field_type_name, "| null") != null;
                if (!is_optional) {
                    var provided = false;
                    for (init.fields) |f| {
                        if (std.mem.eql(u8, f.name, required_name)) {
                            provided = true;
                            break;
                        }
                    }
                    if (!provided) {
                        return compiler_errors.compileFailFmt(
                            state,
                            "missing required field '{s}' in initialization of '{s}'; provide it in the initializer or declare the field optional ('?T')",
                            .{ required_name, ir.cleanTypeName(struct_name) },
                        );
                    }
                }
            }
        }
    }
    if (is_typedef) {
        return try from_ast.resolveNamedType(struct_name, state, ta);
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
                        try env.putConstName(d.name);
                    }
                }
                if (d.is_const) try env.putConstName(d.name);
                return null;
            }
            const prev_lit = env.prefer_literals;
            // `@const $k = "x"` → `"x"`; arrays/arithmetic keep ordinary inference.
            // Explicit `const expr` still enables deep literal typing.
            if (d.is_const and d.value.* == .literal) env.prefer_literals = true;
            defer env.prefer_literals = prev_lit;
            const value_type = try inferExpr(state, env, ta, d.value);
            // Module-level names only: function locals sharing names like `path` / `args`
            // must not clobber `global_types` (breaks multi-module compile / emit).
            // Module-qualified names (`path.lls::cwd`) ARE module globals and must persist
            // so method calls resolve before those decls are emitted.
            // Only genuine module-level declarations persist into `global_types`;
            // declarations inside a nested block (including a `@comptime` block)
            // are scoped to that block and must not leak outward.
            const persist_global = !env.in_function and env.locals.items.len <= 1;
            if (d.type_annotation) |ann| {
                const annot = try from_ast.typeFromAst(ann, state, ta);
                var ctx_buf: [160]u8 = undefined;
                const ctx = std.fmt.bufPrint(&ctx_buf, "declaration of '{s}'", .{d.name}) catch "declaration";
                try requireAssignAt(state, value_type, annot, ctx, d.loc, d.value);
                // Contextual typing: initializer / uses see the annotation width for codegen.
                try recordExprType(state, d.value, annot);
                try env.define(d.name, annot);
                if (persist_global) {
                    const disp = try ownDisplay(state, annot);
                    try state.global_types.put(d.name, disp);
                }
            } else {
                if (state.strict) {
                    if (d.value.* == .array_literal and d.value.array_literal.elements.len == 0) {
                        return compiler_errors.compileFailFmt(state, "cannot infer type for local '${s}' from empty array literal; explicit type annotation required", .{d.name});
                    }
                    if (value_type == .unknown) {
                        return compiler_errors.compileFailFmt(state, "cannot infer type for local '${s}'; explicit type annotation required", .{d.name});
                    }
                }
                if (value_type == .struct_) {
                    try env.define(d.name, value_type);
                    if (persist_global) {
                        const disp = try ownDisplay(state, value_type);
                        try state.global_types.put(d.name, disp);
                    }
                } else if (value_type == .enum_ or value_type == .enum_lit or
                    value_type == .error_set or value_type == .error_lit or
                    value_type == .str_lit or value_type == .int_lit or value_type == .bool_lit or
                    value_type == .tuple or value_type == .defined or value_type == .shape)
                {
                    try env.define(d.name, value_type);
                    // Non-const integer literals store "i64" in global_types so that
                    // cross-module lookups resolve to a parseable type name rather than
                    // the raw literal value ("10", etc.).  @const preserves the literal
                    // display for singleton type matching.
                    if (persist_global) {
                        const disp = if (value_type == .int_lit and !d.is_const)
                            "i64"
                        else
                            try ownDisplay(state, value_type);
                        try state.global_types.put(d.name, disp);
                    }
                } else {
                    try env.define(d.name, value_type);
                    // Persist pointer / array / function displays so emit can resolve layout / types.
                    // Skip `error` — builtin `error` struct would steal LOAD_FIELD from runtime errors.
                    if (persist_global and
                        (value_type == .ptr or value_type == .array or value_type == .func))
                    {
                        const disp = try ownDisplay(state, value_type);
                        try state.global_types.put(d.name, disp);
                    }
                }
            }
            if (d.is_const) try env.putConstName(d.name);
            return null;
        },
        .return_expr => |r| {
            const t = if (r.return_value) |v| try inferExpr(state, env, ta, v) else ir.TNull;
            if (env.expected_return) |er| {
                if (r.return_value) |v| {
                    try requireAssignFrom(state, t, er, "return value", v);
                } else {
                    try requireAssign(state, t, er, "return value");
                }
            }
            return t;
        },
        // `break value` / `continue` feed the enclosing `@switch`/`@for` — not a discard.
        .break_expr => |br| {
            if (br.value) |v| _ = try inferExpr(state, env, ta, v);
            return null;
        },
        .continue_expr => return null,
        .defer_stmt => |d| {
            _ = try checkStmt(state, env, ta, d.body);
            return null;
        },
        .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => return null,
        .block => return try inferExpr(state, env, ta, node),
        else => {
            const t = try inferExpr(state, env, ta, node);
            // Bare expression statement discards the value (emit POP). Warn if error-carrying.
            // Assignments bind the value — not a discard.
            if (node.* != .assignment and !ir.involvesUnknown(t) and ir.isErrorUnion(t)) {
                const loc = node.loc();
                const file_path = if (loc.path.len > 0) loc.path else state.chunk.file;
                const line = if (loc.line > 0) loc.line else 1;
                const col = if (loc.column > 0) loc.column else 1;
                compiler_errors.compileWarnAt(
                    state,
                    file_path,
                    sourceFor(state, file_path),
                    line,
                    col,
                    "error-carrying value discarded; handle with '?', '@isError', '@switch', or bind to a variable",
                    .{},
                );
            }
            return null;
        },
    }
}

fn checkFunction(state: *state_mod.CompilerState, ta: ir.TypeAlloc, f: *ast.FunctionDecl, top_consts: *const std.StringHashMap(void)) TypecheckError!void {
    var env = Env.init(ta.allocator);
    defer env.deinit();

    var cit = top_consts.keyIterator();
    while (cit.next()) |n| try env.putConstName(n.*);

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
    // Two different contracts:
    // • `expected_return` (body return checks) uses the refined display from
    //   refineErrorReturns when it widened the annotation — so an annotated `: Box`
    //   function may `return error(...)` and the caller sees `Box | error`.
    // • `annotated_return` (the `?` policy check) uses the raw annotation —
    //   `?` inside `: i64` is rejected even if refinement ran.
    var expected = annotated;
    if (state.functions.get(f.name)) |def| {
        if (def.return_type) |rt| {
            if (from_ast.typeAllowsError(rt) and (annotated == null or !ir.allowsError(annotated.?))) {
                expected = try from_ast.parseDisplayType(state, ta, rt, null);
            }
        }
    }
    env.annotated_return = annotated;
    env.expected_return = expected;
    env.in_function = true;

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
        if (pnode.type_annotation) |ann| {
            t = try from_ast.typeFromAst(ann, state, ta);
        } else if (state.strict) {
            var is_method_self = false;
            if (std.mem.indexOf(u8, f.name, "::")) |idx| {
                const sname = f.name[0..idx];
                if (state.structs.contains(sname) and i == 0 and std.mem.eql(u8, pnode.name, "self")) {
                    is_method_self = true;
                }
            }
            if (!is_method_self) {
                return compiler_errors.compileFailFmt(state, "parameter '{s}' of function '{s}' must have an explicit type annotation in strict mode; write '{s}: int' (or the intended type)", .{ pnode.name, f.name, pnode.name });
            }
        }
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

    if (expected) |a| {
        if (state.functions.getPtr(f.name)) |def| {
            const disp = try ownDisplay(state, a);
            // `unknown | error` from refineErrorReturns — upgrade success arm from body.
            const weak_success = std.mem.eql(u8, disp, "unknown") or
                std.mem.eql(u8, disp, "error") or
                std.mem.startsWith(u8, disp, "unknown |");
            if (weak_success) {
                if (inferReturnDisplayFromBody(state, f.body)) |better| {
                    var final = better;
                    if (from_ast.typeAllowsError(disp) and !from_ast.typeAllowsError(final)) {
                        const w = try std.fmt.allocPrint(state.allocator, "{s} | error", .{final});
                        try state.owned.append(state.allocator, w);
                        final = w;
                    }
                    def.return_type = final;
                } else {
                    def.return_type = disp;
                }
            } else {
                def.return_type = disp;
            }
        }
    } else if (state.functions.getPtr(f.name)) |def| {
        // Unannotated: refine from return-value types recorded while checking the body
        // (`return sc` after `$sc = @new(...)` is invisible to analyzeBody).
        if (inferReturnDisplayFromBody(state, f.body)) |inferred| {
            const cur = def.return_type;
            const weak = cur == null or
                std.mem.eql(u8, cur.?, "unknown") or
                std.mem.eql(u8, cur.?, "error") or
                std.mem.startsWith(u8, cur.?, "unknown |");
            if (weak) {
                // Preserve `| error` when analyzeBody/refineErrorReturns already saw
                // an error path but body walk only found the success arm.
                var final = inferred;
                if (cur) |c| {
                    if (from_ast.typeAllowsError(c) and !from_ast.typeAllowsError(final)) {
                        const w = std.fmt.allocPrint(state.allocator, "{s} | error", .{final}) catch final;
                        state.owned.append(state.allocator, w) catch {};
                        final = w;
                    }
                }
                def.return_type = final;
            }
        }
    }

    if (state.strict and !std.mem.eql(u8, f.name, "main")) {
        const ret_disp = if (expected) |a| try ownDisplay(state, a) else if (state.functions.get(f.name)) |def| def.return_type else null;
        if (ret_disp) |rd| {
            if (!std.mem.eql(u8, rd, "void") and !nodeAlwaysReturns(f.body)) {
                // Point at the fall-through path: the last statement of the body
                // (or the declaration when the body is empty).
                var end_line: u32 = f.loc.line;
                switch (f.body.*) {
                    .block => |b| {
                        if (b.statements.len > 0) end_line = b.statements[b.statements.len - 1].loc().line;
                    },
                    else => {},
                }
                return compiler_errors.compileFailFmt(
                    state,
                    "function '{s}' must return a value on all control paths; add a 'return <value>' on the path ending at line {d}",
                    .{ f.name, end_line },
                );
            }
        }
    }
}

fn blockAlwaysReturns(block: ast.Block) bool {
    for (block.statements) |s| {
        if (nodeAlwaysReturns(s)) return true;
    }
    return false;
}

fn nodeAlwaysReturns(node: *ast.Node) bool {
    return switch (node.*) {
        .return_expr => true,
        .block => |b| blockAlwaysReturns(b),
        .if_expr => |ife| blk: {
            if (ife.else_body) |eb| {
                break :blk nodeAlwaysReturns(ife.body) and nodeAlwaysReturns(eb);
            }
            break :blk false;
        },
        .switch_expr => |sw| blk: {
            if (sw.prongs.len == 0) break :blk false;
            for (sw.prongs) |p| {
                if (!nodeAlwaysReturns(p.body)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Merge return-value displays from `type_of_results` into a function return display.
fn inferReturnDisplayFromBody(state: *state_mod.CompilerState, body: *ast.Node) ?[]const u8 {
    var success: ?[]const u8 = null;
    var has_error = false;
    walkReturnDisplays(state, body, &success, &has_error);
    if (success) |s| {
        if (has_error and !from_ast.typeAllowsError(s)) {
            const w = std.fmt.allocPrint(state.allocator, "{s} | error", .{s}) catch return s;
            state.owned.append(state.allocator, w) catch {};
            return w;
        }
        return s;
    }
    // Keep a success arm open — pure `error` breaks `T = f()?` when f's success
    // type is not yet refined (call-order / mutual recursion).
    if (has_error) return "unknown | error";
    return null;
}

fn walkReturnDisplays(
    state: *state_mod.CompilerState,
    node: *ast.Node,
    success: *?[]const u8,
    has_error: *bool,
) void {
    switch (node.*) {
        .return_expr => |r| {
            if (r.return_value) |v| {
                if (v.* == .error_expr) {
                    has_error.* = true;
                } else if (state.type_of_results.get(v)) |t| {
                    if (std.mem.eql(u8, t, "error") or std.mem.eql(u8, t, "unknown | error")) {
                        has_error.* = true;
                    } else if (from_ast.typeAllowsError(t)) {
                        has_error.* = true;
                        var arena = std.heap.ArenaAllocator.init(state.allocator);
                        defer arena.deinit();
                        const peeled = from_ast.unwrapErrorDisplay(arena.allocator(), t) catch t;
                        if (!std.mem.eql(u8, peeled, "unknown") and !std.mem.eql(u8, peeled, "null")) {
                            if (success.* == null) {
                                const owned = state.allocator.dupe(u8, peeled) catch peeled;
                                state.owned.append(state.allocator, owned) catch {};
                                success.* = owned;
                            }
                        }
                    } else if (!std.mem.eql(u8, t, "unknown") and !std.mem.eql(u8, t, "null")) {
                        if (success.* == null) success.* = t;
                    }
                } else if (v.* == .call) {
                    // Callee already refined to an error-carrying return (e.g. `self.fail`).
                    if (v.call.callee.* == .member and v.call.callee.member.property.* == .primary) {
                        const prop = v.call.callee.member.property.primary.name;
                        const object = v.call.callee.member.object;
                        if (object.* == .primary and std.mem.eql(u8, object.primary.name, "self")) {
                            var it = state.functions.iterator();
                            while (it.next()) |e| {
                                if (std.mem.endsWith(u8, e.key_ptr.*, prop)) {
                                    const prefix_len = e.key_ptr.*.len - prop.len;
                                    if (prefix_len >= 2 and std.mem.eql(u8, e.key_ptr.*[prefix_len - 2 .. prefix_len], "::")) {
                                        if (e.value_ptr.return_type) |rt| {
                                            if (from_ast.typeAllowsError(rt)) has_error.* = true;
                                        }
                                    }
                                }
                            }
                        }
                    } else if (v.call.callee.* == .primary) {
                        if (state.functions.get(v.call.callee.primary.name)) |def| {
                            if (def.return_type) |rt| {
                                if (from_ast.typeAllowsError(rt)) has_error.* = true;
                            }
                        }
                    }
                }
                walkReturnDisplays(state, v, success, has_error);
            }
        },
        // `expr?` propagates error out of the enclosing function.
        .try_expr => |t| {
            has_error.* = true;
            walkReturnDisplays(state, t.expression, success, has_error);
        },
        .declaration => |d| walkReturnDisplays(state, d.value, success, has_error),
        .assignment => |a| {
            walkReturnDisplays(state, a.left, success, has_error);
            walkReturnDisplays(state, a.right, success, has_error);
        },
        .call => |c| {
            walkReturnDisplays(state, c.callee, success, has_error);
            for (c.args) |a| walkReturnDisplays(state, a, success, has_error);
        },
        .binary => |b| {
            walkReturnDisplays(state, b.left, success, has_error);
            walkReturnDisplays(state, b.right, success, has_error);
        },
        .unary => |u| walkReturnDisplays(state, u.arg, success, has_error),
        .member => |m| walkReturnDisplays(state, m.object, success, has_error),
        .index => |ix| {
            walkReturnDisplays(state, ix.object, success, has_error);
            if (ix.index) |i| walkReturnDisplays(state, i, success, has_error);
            if (ix.end) |e| walkReturnDisplays(state, e, success, has_error);
        },
        .block => |b| for (b.statements) |s| walkReturnDisplays(state, s, success, has_error),
        .if_expr => |i| {
            walkReturnDisplays(state, i.condition, success, has_error);
            walkReturnDisplays(state, i.body, success, has_error);
            if (i.else_body) |e| walkReturnDisplays(state, e, success, has_error);
        },
        .switch_expr => |sw| {
            walkReturnDisplays(state, sw.condition, success, has_error);
            for (sw.prongs) |prong| walkReturnDisplays(state, prong.body, success, has_error);
        },
        .for_expr => |f| {
            walkReturnDisplays(state, f.expr, success, has_error);
            walkReturnDisplays(state, f.body, success, has_error);
        },
        .defer_stmt => |d| walkReturnDisplays(state, d.body, success, has_error),
        else => {},
    }
}

fn checkStructFieldTypes(state: *state_mod.CompilerState, ta: ir.TypeAlloc, s: *const ast.StructDecl) TypecheckError!void {
    const def = state.structs.getPtr(s.name) orelse return;
    for (s.fields) |field| {
        if (field.type_annotation) |ann| {
            const t = try from_ast.typeFromAst(ann, state, ta);
            const disp = try ownDisplay(state, t);
            try def.types.put(field.name, disp);
        } else if (state.strict) {
            return compiler_errors.compileFailFmt(state, "field '{s}' of struct '{s}' must have an explicit type annotation in strict mode; write '{s}: int' (or the intended type)", .{ field.name, s.name, field.name });
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

        try env.putConstName(n.*);
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
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => continue,
            else => _ = try checkStmt(state, &env, ta, s),
        }
    }
}
