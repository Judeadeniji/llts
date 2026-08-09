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
            break :blk try ta.arrayType(elem, a.length);
        },
        .union_type => |u| blk: {
            const left = try typeFromAst(u.left, state, ta);
            const right = try typeFromAst(u.right, state, ta);
            break :blk try ta.unionType(&.{ left, right });
        },
        else => ir.TUnknown,
    };
}

pub fn resolveNamedType(name: []const u8, state: ?*state_mod.CompilerState) FromAstError!ir.Type {
    const t = ir.namedType(name);
    if (t == .struct_) {
        if (state) |st| {
            if (!st.structs.contains(t.struct_)) {
                std.debug.print("CompileError: Unknown type '{s}'\n", .{name});
                return error.CompileError;
            }
        }
    }
    return t;
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
            .boolean => "bool",
            .@"null" => "null",
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
            var object_type = resolveType(state, m.object) orelse break :blk null;
            if (std.mem.indexOfScalar(u8, object_type, '.') != null) {
                object_type = @import("../expr/path.zig").resolveModuleType(state, object_type) catch object_type;
            }
            if (m.property.* != .primary) break :blk null;
            const struct_def = state.structs.get(object_type) orelse break :blk null;
            break :blk struct_def.types.get(m.property.primary.name);
        },
        .call => |c| blk: {
            if (c.callee.* == .primary) {
                if (state.functions.get(c.callee.primary.name)) |def| break :blk def.return_type;
            }
            if (@import("../expr/path.zig").tryResolveStaticPath(state, c.callee) catch null) |path| {
                if (state.functions.get(path)) |def| break :blk def.return_type;
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
        .struct_init => |s| s.name,
        .unary => |u| resolveType(state, u.arg),
        else => null,
    };
}

pub fn isStringyType(t: ?[]const u8) bool {
    const s = t orelse return false;
    if (std.mem.eql(u8, s, "string") or std.mem.eql(u8, s, "[]byte")) return true;
    return std.mem.startsWith(u8, s, "[") and std.mem.endsWith(u8, s, "]byte");
}
