const std = @import("std");
const ast = @import("../../ast/root.zig");
const ir = @import("ir.zig");
const state_mod = @import("../state.zig");
const scope = @import("../scope.zig");

pub const FromAstError = error{ OutOfMemory, CompileError };

/// Convert AST type node → Type IR. Validates unknown struct names when state is set.
pub fn typeFromAst(node: ?*ast.Node, state: ?*state_mod.CompilerState, ta: ir.TypeAlloc) FromAstError!ir.Type {
    const n = node orelse return ir.TUnknown;
    return switch (n.*) {
        .primary => |p| try resolveNamedType(p.name, state),
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
        .pointer_type => |p| try ta.ptrType(try typeFromAst(p.elem, state, ta)),
        .union_type => |u| blk: {
            const left = try typeFromAst(u.left, state, ta);
            const right = try typeFromAst(u.right, state, ta);
            break :blk try ta.unionType(&.{ left, right });
        },
        .member => try resolveImportedType(n, state),
        else => ir.TUnknown,
    };
}

pub fn resolveNamedType(name: []const u8, state: ?*state_mod.CompilerState) FromAstError!ir.Type {
    const t = ir.namedType(name);
    if (t != .struct_) return t;
    if (state) |st| {
        if (st.enums.contains(name)) return .{ .enum_ = name };
        if (st.structs.contains(name)) return .{ .struct_ = name };
        return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown type '{s}'", .{name});
    }
    return t;
}

fn resolveImportedType(node: *ast.Node, state: ?*state_mod.CompilerState) FromAstError!ir.Type {
    const st = state orelse return ir.TUnknown;
    const q = resolveStructName(st, node) orelse {
        return @import("../../errors/compile.zig").compileFailFmt(st, "Unknown type", .{});
    };
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

pub fn lookupStruct(state: *state_mod.CompilerState, display: []const u8) ?state_mod.StructDef {
    return state.structs.get(unwrapOptionalDisplay(display));
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
                if (std.mem.indexOfScalar(u8, tn, '.') != null) {
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
            const struct_def = lookupStruct(state, object_type) orelse break :blk null;
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
            const elem = arrayElemDisplay(state.allocator, obj) catch break :blk null;
            if (elem) |e| {
                state.owned.append(state.allocator, e) catch {};
                break :blk e;
            }
            break :blk null;
        },
        .array_literal => |a| blk: {
            if (a.elements.len == 0) break :blk "[0]unknown";
            // Infer from first element; prefer concrete element types.
            const first = resolveType(state, a.elements[0]) orelse "unknown";
            // Nested array literal length check is done in typecheck; here best-effort.
            const s = std.fmt.allocPrint(state.allocator, "[{d}]{s}", .{ a.elements.len, first }) catch break :blk null;
            state.owned.append(state.allocator, s) catch {};
            break :blk s;
        },
        .struct_init => |s| resolveStructName(state, s.type_expr),
        .unary => |u| blk: {
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
