const std = @import("std");
const ast = @import("../../ast/root.zig");
const ir = @import("ir.zig");
const state_mod = @import("../state.zig");
const scope = @import("../scope.zig");

pub const FromAstError = error{ OutOfMemory, CompileError, Overflow, InvalidCharacter };

/// Convert AST type node → Type IR. Validates unknown struct names when state is set.
pub fn typeFromAst(node: ?*ast.Node, state: ?*state_mod.CompilerState, ta: ir.TypeAlloc) FromAstError!ir.Type {
    const n = node orelse return ir.TUnknown;
    return switch (n.*) {
        .primary => |p| try resolveNamedType(p.name, state, ta),
        .literal => |lit| try literalTypeFromAst(state, lit),
        .array_type => |a| blk: {
            const elem = try typeFromAst(a.elem, state, ta);
            var length: ?usize = null;
            if (a.length_text) |text| {
                const parsed_len = parseArrayLengthString(text) catch |err| {
                    if (state) |st| {
                        return @import("../../errors/compile.zig").compileFailFmt(st, "Invalid array length '{s}'", .{text});
                    }
                    return err;
                };
                length = parsed_len;
            }
            break :blk try ta.arrayType(elem, length);
        },
        .tuple_type => |t| blk: {
            var elems: std.ArrayList(ir.Type) = .empty;
            defer elems.deinit(ta.allocator);
            for (t.elems) |e| {
                try elems.append(ta.allocator, try typeFromAst(e, state, ta));
            }
            break :blk try ta.tupleType(elems.items);
        },
        .pointer_type => |p| try ta.ptrType(try typeFromAst(p.elem, state, ta)),
        .func_type => |f| blk: {
            var params: std.ArrayList(ir.Type) = .empty;
            defer params.deinit(ta.allocator);
            for (f.params) |p| {
                try params.append(ta.allocator, try typeFromAst(p, state, ta));
            }
            const ret = if (f.return_type) |rt| try typeFromAst(rt, state, ta) else ir.TUnknown;
            break :blk try ta.funcType(params.items, ret, f.is_variadic);
        },
        .union_type => |u| blk: {
            const left = try typeFromAst(u.left, state, ta);
            const right = try typeFromAst(u.right, state, ta);
            break :blk try ta.unionType(&.{ left, right });
        },
        .member => try resolveImportedType(n, state, ta),
        else => ir.TUnknown,
    };
}

fn literalTypeFromAst(state: ?*state_mod.CompilerState, lit: ast.Literal) FromAstError!ir.Type {
    return switch (lit.literal_type) {
        .string => .{ .str_lit = lit.value },
        .boolean => .{ .bool_lit = std.mem.eql(u8, lit.value, "true") },
        .number, .hex, .octal, .binary => blk: {
            if (std.mem.indexOfScalar(u8, lit.value, '.') != null or
                std.mem.indexOfScalar(u8, lit.value, 'e') != null or
                std.mem.indexOfScalar(u8, lit.value, 'E') != null)
            {
                if (state) |st| {
                    return @import("../../errors/compile.zig").compileFailFmt(st, "Float literals are not valid types (use f32/f64)", .{});
                }
                return error.CompileError;
            }
            const n: i64 = switch (lit.literal_type) {
                .hex => std.fmt.parseInt(i64, lit.value[2..], 16) catch return error.CompileError,
                .octal => std.fmt.parseInt(i64, lit.value[2..], 8) catch return error.CompileError,
                .binary => std.fmt.parseInt(i64, lit.value[2..], 2) catch return error.CompileError,
                else => std.fmt.parseInt(i64, lit.value, 10) catch return error.CompileError,
            };
            break :blk .{ .int_lit = n };
        },
        .null => ir.TNull,
    };
}

pub fn resolveNamedType(name: []const u8, state: ?*state_mod.CompilerState, ta: ir.TypeAlloc) FromAstError!ir.Type {
    const t = ir.namedType(name);
    if (t != .struct_) return t;
    if (state) |st| {
        if (st.typedefs.contains(name)) {
            return try resolveTypedef(st, ta, name, null);
        }
        if (st.enums.contains(name)) return .{ .enum_ = name };
        if (st.structs.contains(name)) return .{ .struct_ = name };
        return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown type '{s}'", .{name});
    }
    return t;
}

fn resolveTypedef(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    name: []const u8,
    stack: ?*std.StringHashMap(void),
) FromAstError!ir.Type {
    const td = state.typedefs.get(name) orelse {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Unknown type '{s}'", .{name});
    };

    var owned_stack: ?std.StringHashMap(void) = null;
    defer if (owned_stack) |*s| s.deinit();
    const seen = stack orelse blk: {
        owned_stack = std.StringHashMap(void).init(ta.allocator);
        break :blk &owned_stack.?;
    };
    if (seen.contains(name)) {
        return @import("../../errors/compile.zig").compileFailFmt(state, "Cyclic type definition involving '{s}'", .{name});
    }
    try seen.put(name, {});

    const under = try parseDisplayType(state, ta, td.underlying, seen);
    if (!td.distinct) return under;
    return try ta.definedType(td.name, under);
}

/// Like `ir.parseDisplayType` but resolves `@type` / `@alias` / structs / enums via `state`.
pub fn parseDisplayType(
    state: ?*state_mod.CompilerState,
    ta: ir.TypeAlloc,
    s_in: []const u8,
    cycle: ?*std.StringHashMap(void),
) FromAstError!ir.Type {
    const s = std.mem.trim(u8, s_in, " \t");
    const union_parts = try ir.splitTopLevel(ta.allocator, s, " | ");
    defer ta.allocator.free(union_parts);
    if (union_parts.len > 1) {
        var arms: std.ArrayList(ir.Type) = .empty;
        defer arms.deinit(ta.allocator);
        for (union_parts) |part| {
            try arms.append(ta.allocator, try parseDisplayType(state, ta, part, cycle));
        }
        return try ta.unionType(arms.items);
    }
    if (s.len > 0 and s[0] == '?') {
        const inner = try parseDisplayType(state, ta, s[1..], cycle);
        return try ta.unionType(&.{ inner, ir.TNull });
    }
    if (s.len > 0 and s[0] == '*') {
        return try ta.ptrType(try parseDisplayType(state, ta, s[1..], cycle));
    }
    if (s.len > 0 and s[0] == '[') {
        if (s.len >= 2 and s[1] == ']') {
            return try ta.arrayType(try parseDisplayType(state, ta, s[2..], cycle), null);
        }
        var depth: i32 = 0;
        var close: ?usize = null;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '[') depth += 1;
            if (c == ']') {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            }
        }
        const end = close orelse return error.CompileError;
        const interior = s[1..end];
        const rest = std.mem.trim(u8, s[end + 1 ..], " \t");
        if (rest.len > 0) {
            const len = std.fmt.parseInt(usize, interior, 10) catch return error.CompileError;
            return try ta.arrayType(try parseDisplayType(state, ta, rest, cycle), len);
        }
        const parts = try ir.splitTopLevel(ta.allocator, interior, ", ");
        defer ta.allocator.free(parts);
        var elems: std.ArrayList(ir.Type) = .empty;
        defer elems.deinit(ta.allocator);
        for (parts) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            try elems.append(ta.allocator, try parseDisplayType(state, ta, p, cycle));
        }
        return try ta.tupleType(elems.items);
    }
    if (try parseFuncDisplayType(state, ta, s, cycle)) |ft| return ft;
    // Literal types stored as displays: `"a"`, `42`, `true`
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        const inner = try ta.allocator.dupe(u8, s[1 .. s.len - 1]);
        return .{ .str_lit = inner };
    }
    if (std.mem.eql(u8, s, "true")) return .{ .bool_lit = true };
    if (std.mem.eql(u8, s, "false")) return .{ .bool_lit = false };
    if (s.len > 0 and (s[0] == '-' or (s[0] >= '0' and s[0] <= '9'))) {
        if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null and std.mem.indexOfScalar(u8, s, 'E') == null) {
            if (std.fmt.parseInt(i64, s, 10)) |n| {
                return .{ .int_lit = n };
            } else |_| {}
        }
    }
    if (state) |st| {
        if (st.typedefs.contains(s)) {
            return try resolveTypedef(st, ta, s, cycle);
        }
        // Builtins / widths before struct table (`string` is also a layout struct).
        const builtin = ir.namedType(s);
        if (builtin != .struct_) return builtin;
        if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
            const ename = s[0..dot];
            const vname = s[dot + 1 ..];
            if (st.enums.get(ename)) |ed| {
                if (ed.variants.contains(vname)) {
                    return .{ .enum_lit = .{ .enum_name = ename, .variant = vname } };
                }
            }
        }
        if (st.enums.contains(s)) return .{ .enum_ = s };
        if (st.structs.contains(s)) return .{ .struct_ = s };
        return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown type '{s}'", .{s});
    }
    return try ir.parseDisplayType(ta, s);
}

fn parseFuncDisplayType(
    state: ?*state_mod.CompilerState,
    ta: ir.TypeAlloc,
    s: []const u8,
    cycle: ?*std.StringHashMap(void),
) FromAstError!?ir.Type {
    const parts = (try ir.splitFuncDisplay(s)) orelse return null;
    var params: std.ArrayList(ir.Type) = .empty;
    defer params.deinit(ta.allocator);
    var variadic = false;
    if (parts.params.len > 0) {
        const param_parts = try ir.splitTopLevel(ta.allocator, parts.params, ", ");
        defer ta.allocator.free(param_parts);
        for (param_parts, 0..) |part, pi| {
            var p = std.mem.trim(u8, part, " \t");
            if (std.mem.startsWith(u8, p, "...")) {
                if (pi + 1 != param_parts.len) return error.CompileError;
                variadic = true;
                p = std.mem.trim(u8, p[3..], " \t");
            }
            try params.append(ta.allocator, try parseDisplayType(state, ta, p, cycle));
        }
    }
    const ret = if (parts.ret) |r| try parseDisplayType(state, ta, r, cycle) else ir.TUnknown;
    return try ta.funcType(params.items, ret, variadic);
}

fn resolveImportedType(node: *ast.Node, state: ?*state_mod.CompilerState, ta: ir.TypeAlloc) FromAstError!ir.Type {
    const st = state orelse return ir.TUnknown;

    // `ExprKind.Literal` — enum variant as a singleton type.
    if (node.* == .member and node.member.property.* == .primary) {
        if (resolveEnumName(st, node.member.object)) |ename| {
            const vname = node.member.property.primary.name;
            if (st.enums.get(ename)) |ed| {
                if (ed.variants.contains(vname)) {
                    return .{ .enum_lit = .{ .enum_name = ename, .variant = vname } };
                }
                return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown enum variant '{s}' on '{s}'", .{ vname, ename });
            }
        }
    }

    const q = resolveStructName(st, node) orelse {
        return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown type", .{});
    };
    if (st.typedefs.contains(q)) {
        try checkStructInitExport(st, node, q);
        return try resolveTypedef(st, ta, q, null);
    }
    if (st.enums.contains(q)) {
        try checkStructInitExport(st, node, q);
        return .{ .enum_ = q };
    }
    if (st.structs.contains(q)) {
        try checkStructInitExport(st, node, q);
        return .{ .struct_ = q };
    }
    const short = if (node.* == .member and node.member.property.* == .primary)
        node.member.property.primary.name
    else
        q;
    return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown type '{s}'", .{short});
}

/// Strip optional / pointer wrappers from a type display for struct name lookup:
/// `?*Node` / `*Node` / `?Node` / `Node | null` → `Node`.
pub fn unwrapOptionalDisplay(display: []const u8) []const u8 {
    var t = std.mem.trim(u8, display, " \t");
    while (t.len > 0 and t[0] == '?') {
        t = std.mem.trim(u8, t[1..], " \t");
    }
    if (std.mem.endsWith(u8, t, " | null")) {
        t = std.mem.trim(u8, t[0 .. t.len - 7], " \t");
    } else if (std.mem.startsWith(u8, t, "null | ")) {
        t = std.mem.trim(u8, t[7..], " \t");
    }
    while (t.len > 0 and t[0] == '*') {
        t = std.mem.trim(u8, t[1..], " \t");
    }
    return t;
}

/// Unwrap `@alias` fully and `@type` one step for layout / discrim lookup.
pub fn peelTypedefDisplay(state: *state_mod.CompilerState, display: []const u8) []const u8 {
    var cur = unwrapOptionalDisplay(display);
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        const td = state.typedefs.get(cur) orelse return cur;
        cur = unwrapOptionalDisplay(td.underlying);
        if (td.distinct) return cur; // one step for distinct (keep nominal elsewhere)
    }
    return cur;
}

pub fn lookupStruct(state: *state_mod.CompilerState, display: []const u8) ?state_mod.StructDef {
    return state.structs.get(peelTypedefDisplay(state, display));
}

/// Split a top-level `A | B | C` display (no nested parens needed for simple struct unions).
pub fn splitUnionDisplay(allocator: std.mem.Allocator, display: []const u8) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < display.len) {
        if (i + 2 < display.len and display[i] == ' ' and display[i + 1] == '|' and display[i + 2] == ' ') {
            const part = std.mem.trim(u8, display[start..i], " \t");
            if (part.len > 0) try parts.append(allocator, part);
            i += 3;
            start = i;
            continue;
        }
        i += 1;
    }
    const last = std.mem.trim(u8, display[start..], " \t");
    if (last.len > 0) try parts.append(allocator, last);
    return try parts.toOwnedSlice(allocator);
}

/// If `display` is a struct union whose arms share field `field` at the same offset, return one arm's def.
pub fn lookupStructField(
    state: *state_mod.CompilerState,
    display: []const u8,
    field: []const u8,
) ?struct { def: state_mod.StructDef, offset: i32, field_ty: []const u8 } {
    const bare = peelTypedefDisplay(state, display);
    if (lookupStruct(state, bare)) |sd| {
        const off = sd.offsets.get(field) orelse return null;
        const ty = sd.types.get(field) orelse return null;
        return .{ .def = sd, .offset = off, .field_ty = ty };
    }
    // Struct union: `Literal | Add`
    if (std.mem.indexOf(u8, bare, " | ") == null) return null;
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const parts = splitUnionDisplay(arena.allocator(), bare) catch return null;
    if (parts.len < 2) return null;

    var first_off: ?i32 = null;
    var first_ty: ?[]const u8 = null;
    var first_def: ?state_mod.StructDef = null;
    for (parts) |part| {
        const sd = state.structs.get(std.mem.trim(u8, part, " \t")) orelse return null;
        const off = sd.offsets.get(field) orelse return null;
        const ty = sd.types.get(field) orelse return null;
        if (first_off) |fo| {
            if (fo != off) return null; // layout must agree for un-narrowed access
        } else {
            first_off = off;
            first_ty = ty;
            first_def = sd;
        }
    }
    return .{ .def = first_def.?, .offset = first_off.?, .field_ty = first_ty.? };
}

/// Map enum variant → struct name for a discriminated struct union (`kind: Enum.Variant` fields).
pub fn discrimVariantMap(
    state: *state_mod.CompilerState,
    allocator: std.mem.Allocator,
    display: []const u8,
) !?struct { enum_name: []const u8, map: std.StringHashMap([]const u8) } {
    const bare = peelTypedefDisplay(state, display);
    if (std.mem.indexOf(u8, bare, " | ") == null) return null;
    const parts = try splitUnionDisplay(allocator, bare);
    defer allocator.free(parts);
    if (parts.len < 2) return null;

    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();
    var enum_name: ?[]const u8 = null;

    for (parts) |part| {
        const sname = std.mem.trim(u8, part, " \t");
        const sd = state.structs.get(sname) orelse {
            map.deinit();
            return null;
        };
        const kind_ty = sd.types.get("kind") orelse {
            map.deinit();
            return null;
        };
        // Expect `ExprKind.Literal`
        const dot = std.mem.lastIndexOfScalar(u8, kind_ty, '.') orelse {
            map.deinit();
            return null;
        };
        const ename = kind_ty[0..dot];
        const vname = kind_ty[dot + 1 ..];
        if (!state.enums.contains(ename)) {
            map.deinit();
            return null;
        }
        if (enum_name) |en| {
            if (!std.mem.eql(u8, en, ename)) {
                map.deinit();
                return null;
            }
        } else {
            enum_name = ename;
        }
        try map.put(vname, sname);
    }
    return .{ .enum_name = enum_name.?, .map = map };
}

pub fn parseArrayLengthString(raw: []const u8) FromAstError!usize {
    const n: i64 = if (std.mem.startsWith(u8, raw, "0x"))
        std.fmt.parseInt(i64, raw[2..], 16) catch return error.CompileError
    else if (std.mem.startsWith(u8, raw, "0b"))
        std.fmt.parseInt(i64, raw[2..], 2) catch return error.CompileError
    else if (std.mem.startsWith(u8, raw, "0o"))
        std.fmt.parseInt(i64, raw[2..], 8) catch return error.CompileError
    else
        std.fmt.parseInt(i64, raw, 10) catch return error.CompileError;
    if (n < 0) return error.CompileError;
    return @intCast(n);
}


/// Display string for a type AST node. Validates unknown types when state is provided.
pub fn typeAstToDisplay(node: ?*ast.Node, state: ?*state_mod.CompilerState) FromAstError!?[]const u8 {
    const n = node orelse return null;
    var arena = std.heap.ArenaAllocator.init(if (state) |st| st.allocator else std.heap.page_allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };
    const t = try typeFromAst(n, state, ta);
    if (state) |st| {
        const s = try ir.displayTypeAlloc(st.allocator, t);
        try st.owned.append(st.allocator, s);
        return s;
    }
    return ir.displayTypeSimple(t);
}

pub fn typeAllowsError(display: []const u8) bool {
    if (std.mem.eql(u8, display, "error")) return true;
    var it = std.mem.splitSequence(u8, display, "|");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, trimmed, "error")) return true;
    }
    return false;
}

/// Strip ` | error` arms from a display string.
pub fn unwrapErrorDisplay(allocator: std.mem.Allocator, display: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var it = std.mem.splitSequence(u8, display, "|");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (!std.mem.eql(u8, trimmed, "error")) try parts.append(allocator, trimmed);
    }
    if (parts.items.len == 0) return try allocator.dupe(u8, "error");
    if (parts.items.len == 1) return try allocator.dupe(u8, parts.items[0]);
    var total: usize = 0;
    for (parts.items, 0..) |p, i| {
        total += p.len;
        if (i > 0) total += 3;
    }
    var out = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (parts.items, 0..) |p, i| {
        if (i > 0) {
            @memcpy(out[offset .. offset + 3], " | ");
            offset += 3;
        }
        @memcpy(out[offset .. offset + p.len], p);
        offset += p.len;
    }
    return out;
}

/// Element type display for an array type string like `[2][3]int` → `[3]int`, `[]int` → `int`.
pub fn arrayElemDisplay(allocator: std.mem.Allocator, display: []const u8) !?[]const u8 {
    const s = std.mem.trim(u8, display, " \t");
    if (s.len == 0 or s[0] != '[') return null;
    if (s.len >= 2 and s[1] == ']') {
        return try allocator.dupe(u8, s[2..]);
    }
    var i: usize = 1;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i < s.len and s[i] == ']') {
        return try allocator.dupe(u8, s[i + 1 ..]);
    }
    return null;
}

pub fn resolveType(state: *state_mod.CompilerState, node: *ast.Node) ?[]const u8 {
    return switch (node.*) {
        .literal => |lit| switch (lit.literal_type) {
            .string => blk: {
                const s = std.fmt.allocPrint(state.allocator, "[{d}]byte", .{lit.value.len}) catch break :blk "[]byte";
                state.owned.append(state.allocator, s) catch {};
                break :blk s;
            },
            .boolean => "u1",
            .@"null" => "null",
            .number => blk: {
                // Float if the source spelling contains '.' or exponent.
                if (std.mem.indexOfScalar(u8, lit.value, '.') != null or
                    std.mem.indexOfScalar(u8, lit.value, 'e') != null or
                    std.mem.indexOfScalar(u8, lit.value, 'E') != null)
                {
                    break :blk "f64";
                }
                break :blk "int";
            },
            else => "int",
        },
        .primary => |p| blk: {
            if (p.kind != .identifier and p.kind != .register) break :blk null;
            const local_idx = scope.resolveLocal(state, p.name);
            var type_name: ?[]const u8 = if (local_idx != -1)
                state.locals.items[@intCast(local_idx)].type_name
            else
                state.global_types.get(p.name);
            if (type_name) |tn| {
                // Don't treat `ExprKind.Literal` as `mod.Type`.
                const looks_enum_lit = lit: {
                    if (std.mem.indexOf(u8, tn, "::") != null) break :lit false;
                    if (std.mem.lastIndexOfScalar(u8, tn, '.')) |dot| {
                        break :lit state.enums.contains(tn[0..dot]);
                    }
                    break :lit false;
                };
                if (!looks_enum_lit and std.mem.indexOfScalar(u8, tn, '.') != null) {
                    type_name = @import("../expr/path.zig").resolveModuleType(state, tn) catch tn;
                }
            }
            break :blk type_name;
        },
        .member => |m| blk: {
            if (m.property.* != .primary) break :blk null;
            if (resolveEnumName(state, m.object)) |ename| {
                if (state.enums.get(ename)) |ed| {
                    if (ed.variants.contains(m.property.primary.name)) break :blk ename;
                }
                break :blk null;
            }
            // Imported value: `io.stdout` → type of global `mod::stdout`.
            if (@import("../expr/path.zig").tryResolveStaticPath(state, node) catch null) |static_path| {
                if (state.global_types.get(static_path)) |gt| {
                    if (!std.mem.startsWith(u8, gt, "module:")) break :blk gt;
                }
            }
            var object_type = resolveType(state, m.object) orelse break :blk null;
            if (std.mem.indexOfScalar(u8, object_type, '.') != null) {
                object_type = @import("../expr/path.zig").resolveModuleType(state, object_type) catch object_type;
            }
            // Module namespace (`module:path`) — field types come from exported globals.
            if (std.mem.startsWith(u8, object_type, "module:")) {
                const mod_path = object_type["module:".len..];
                var qbuf: [512]u8 = undefined;
                const q = std.fmt.bufPrint(&qbuf, "{s}::{s}", .{ mod_path, m.property.primary.name }) catch break :blk null;
                if (state.global_types.get(q)) |gt| {
                    if (!std.mem.startsWith(u8, gt, "module:")) break :blk gt;
                }
                break :blk null;
            }
            const struct_def = lookupStruct(state, object_type) orelse {
                // Struct union field (common fields only, e.g. `kind`).
                if (m.property.* == .primary) {
                    if (lookupStructField(state, object_type, m.property.primary.name)) |info| {
                        // Discrim `kind` on `A | B` → parent enum (not first arm's singleton).
                        if (std.mem.eql(u8, m.property.primary.name, "kind")) {
                            if (discrimVariantMap(state, state.allocator, object_type) catch null) |dinfo_owned| {
                                var dinfo = dinfo_owned;
                                defer dinfo.map.deinit();
                                break :blk dinfo.enum_name;
                            }
                        }
                        break :blk info.field_ty;
                    }
                }
                break :blk null;
            };
            break :blk struct_def.types.get(m.property.primary.name);
        },
        .call => |c| blk: {
            if (c.callee.* == .primary) {
                if (state.functions.get(c.callee.primary.name)) |def| break :blk def.return_type;
            }
            if (@import("../expr/path.zig").tryResolveStaticPath(state, c.callee) catch null) |p| {
                if (state.functions.get(p)) |def| break :blk def.return_type;
            }
            // Method call: obj.method() — resolve via Struct::method
            if (c.callee.* == .member) {
                const mem = &c.callee.member;
                if (mem.property.* == .primary) {
                    const prop = mem.property.primary.name;
                    if (resolveType(state, mem.object)) |obj_type| {
                        const struct_name = unwrapOptionalDisplay(obj_type);
                        var buf: [256]u8 = undefined;
                        const method_name = std.fmt.bufPrint(&buf, "{s}::{s}", .{ struct_name, prop }) catch break :blk null;
                        if (state.functions.get(method_name)) |def| break :blk def.return_type;
                    }
                }
            }
            break :blk null;
        },
        .try_expr => |t| blk: {
            const inner = resolveType(state, t.expression) orelse break :blk null;
            if (!typeAllowsError(inner)) break :blk inner;
            const unwrapped = unwrapErrorDisplay(state.allocator, inner) catch break :blk null;
            state.owned.append(state.allocator, unwrapped) catch {};
            break :blk unwrapped;
        },
        .index => |idx| blk: {
            const obj = resolveType(state, idx.object) orelse break :blk null;
            if (idx.is_slice) {
                // Slice views are unsized `[]T` / `[]byte`.
                if (std.mem.eql(u8, obj, "string") or std.mem.eql(u8, obj, "[]byte")) break :blk "[]byte";
                if (arrayElemDisplay(state.allocator, obj) catch null) |e| {
                    const s = std.fmt.allocPrint(state.allocator, "[]{s}", .{e}) catch break :blk null;
                    state.allocator.free(e);
                    state.owned.append(state.allocator, s) catch {};
                    break :blk s;
                }
                break :blk null;
            }
            const elem = arrayElemDisplay(state.allocator, obj) catch break :blk null;
            if (elem) |e| {
                state.owned.append(state.allocator, e) catch {};
                break :blk e;
            }
            break :blk null;
        },
        .array_literal => |a| blk: {
            if (a.elements.len == 0) break :blk "[0]unknown";
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(state.allocator);
            for (a.elements) |el| {
                const t = resolveType(state, el) orelse "unknown";
                parts.append(state.allocator, t) catch break :blk null;
            }
            // Homogeneous → `[N]T`; else tuple `[T, U, …]`.
            var homo = true;
            const first = parts.items[0];
            for (parts.items[1..]) |p| {
                if (!std.mem.eql(u8, p, first)) {
                    homo = false;
                    break;
                }
            }
            if (homo) {
                const s = std.fmt.allocPrint(state.allocator, "[{d}]{s}", .{ a.elements.len, first }) catch break :blk null;
                state.owned.append(state.allocator, s) catch {};
                break :blk s;
            }
            var total: usize = 2;
            for (parts.items, 0..) |p, pi| {
                total += p.len;
                if (pi > 0) total += 2;
            }
            const out = state.allocator.alloc(u8, total) catch break :blk null;
            out[0] = '[';
            var off: usize = 1;
            for (parts.items, 0..) |p, pi| {
                if (pi > 0) {
                    @memcpy(out[off .. off + 2], ", ");
                    off += 2;
                }
                @memcpy(out[off .. off + p.len], p);
                off += p.len;
            }
            out[off] = ']';
            state.owned.append(state.allocator, out) catch {};
            break :blk out;
        },
        .struct_init => |s| resolveStructName(state, s.type_expr),
        .unary => |u| blk: {
            if (std.mem.eql(u8, u.operator, "const")) {
                break :blk resolveTypeLiteral(state, u.arg);
            }
            if (std.mem.eql(u8, u.operator, "&")) {
                const inner = resolveType(state, u.arg) orelse break :blk null;
                const s = std.fmt.allocPrint(state.allocator, "*{s}", .{inner}) catch break :blk null;
                state.owned.append(state.allocator, s) catch {};
                break :blk s;
            }
            break :blk resolveType(state, u.arg);
        },
        else => null,
    };
}

/// Emit-time display for `const expr` — singleton / deep-literal forms.
fn resolveTypeLiteral(state: *state_mod.CompilerState, node: *ast.Node) ?[]const u8 {
    return switch (node.*) {
        .literal => |lit| switch (lit.literal_type) {
            .string => blk: {
                const s = std.fmt.allocPrint(state.allocator, "\"{s}\"", .{lit.value}) catch break :blk null;
                state.owned.append(state.allocator, s) catch {};
                break :blk s;
            },
            .boolean => if (std.mem.eql(u8, lit.value, "true")) "true" else "false",
            .@"null" => "null",
            .number => blk: {
                if (std.mem.indexOfScalar(u8, lit.value, '.') != null or
                    std.mem.indexOfScalar(u8, lit.value, 'e') != null or
                    std.mem.indexOfScalar(u8, lit.value, 'E') != null)
                {
                    break :blk "f64";
                }
                break :blk lit.value;
            },
            .hex, .octal, .binary => lit.value,
        },
        .array_literal => |a| blk: {
            if (a.elements.len == 0) break :blk "[0]unknown";
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(state.allocator);
            for (a.elements) |el| {
                const t = resolveTypeLiteral(state, el) orelse resolveType(state, el) orelse "unknown";
                parts.append(state.allocator, t) catch break :blk null;
            }
            var total: usize = 2;
            for (parts.items, 0..) |p, pi| {
                total += p.len;
                if (pi > 0) total += 2;
            }
            const out = state.allocator.alloc(u8, total) catch break :blk null;
            out[0] = '[';
            var off: usize = 1;
            for (parts.items, 0..) |p, pi| {
                if (pi > 0) {
                    @memcpy(out[off .. off + 2], ", ");
                    off += 2;
                }
                @memcpy(out[off .. off + p.len], p);
                off += p.len;
            }
            out[off] = ']';
            state.owned.append(state.allocator, out) catch {};
            break :blk out;
        },
        .unary => |u| if (std.mem.eql(u8, u.operator, "const"))
            resolveTypeLiteral(state, u.arg)
        else
            resolveType(state, node),
        else => resolveType(state, node),
    };
}

pub fn isStringyType(t: ?[]const u8) bool {
    const s = t orelse return false;
    if (std.mem.eql(u8, s, "string") or std.mem.eql(u8, s, "[]byte")) return true;
    return std.mem.startsWith(u8, s, "[") and std.mem.endsWith(u8, s, "]byte");
}

/// If `node` names an enum type (`Tok` or `lib.Tok`), return the (possibly module-qualified) enum name.
pub fn resolveEnumName(state: *state_mod.CompilerState, node: *ast.Node) ?[]const u8 {
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) return null;
            if (state.enums.contains(p.name)) return p.name;
            return null;
        },
        .member => |m| {
            if (m.object.* != .primary or m.property.* != .primary) return null;
            const alias = m.object.primary.name;
            const short = m.property.primary.name;
            var buf: [256]u8 = undefined;
            const dotted = std.fmt.bufPrint(&buf, "{s}.{s}", .{ alias, short }) catch return null;
            const q = @import("../expr/path.zig").resolveModuleType(state, dotted) catch return null;
            if (state.enums.contains(q)) return q;
            return null;
        },
        else => return null,
    }
}

pub fn resolveStructName(state: *state_mod.CompilerState, node: *ast.Node) ?[]const u8 {
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier) return null;
            if (state.structs.contains(p.name)) return p.name;
            var buf: [256]u8 = undefined;
            const re_key = std.fmt.bufPrint(&buf, "${s}", .{p.name}) catch return null;
            if (state.global_types.get(re_key)) |rt| {
                if (!std.mem.startsWith(u8, rt, "module:")) return rt;
            }
            return p.name; // unresolved base name
        },
        .member => |m| {
            if (m.property.* != .primary) return null;
            const obj_path = @import("../expr/path.zig").tryResolveStaticPath(state, m.object) catch null orelse return null;
            const q = std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ obj_path, m.property.primary.name }) catch return null;
            state.owned.append(state.allocator, q) catch {};
            return q;
        },
        else => return null,
    }
}

/// Reject `mod.Private { … }` when `Private` is not exported from the imported module.
pub fn checkStructInitExport(state: *state_mod.CompilerState, type_expr: *ast.Node, qualified: []const u8) FromAstError!void {
    if (type_expr.* != .member) return;
    const mem = type_expr.member;
    if (mem.object.* != .primary or mem.property.* != .primary) return;
    if (std.mem.indexOf(u8, qualified, "::") == null) return;
    if (state.chunk.exports.contains(qualified)) return;
    return @import("../../errors/compile.zig").compileFailFmt(state, "'{s}' has no export '{s}'", .{
        mem.object.primary.name,
        mem.property.primary.name,
    });
}
