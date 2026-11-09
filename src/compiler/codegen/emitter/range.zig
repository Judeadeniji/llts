const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const widths = @import("../../widths.zig");
const root_mod = @import("root.zig");

const Emitter = root_mod.Emitter;
const IntRange = root_mod.IntRange;
const Product = struct {
    value: i64,
    overflow: u1,
};

pub fn ofExpr(self: *Emitter, node: *ast_mod.Node) ?IntRange {
    return switch (node.*) {
        .literal => |lit| literal(lit),
        .primary => |p| primary(self, p),
        .unary => |u| unary(self, &u),
        .binary => |b| binary(self, &b),
        .comptime_expr => |ce| ofExpr(self, ce.expr),
        else => null,
    };
}

pub fn resultFits(self: *Emitter, left: *ast_mod.Node, right: *ast_mod.Node, op: []const u8, width: widths.Width) bool {
    const lhs = ofExpr(self, left) orelse return false;
    const rhs = ofExpr(self, right) orelse return false;
    const result = combine(lhs, rhs, op) orelse return false;
    return widths.i64Fits(width, result.min) and widths.i64Fits(width, result.max);
}

pub fn loopCapture(self: *Emitter, f: *const ast_mod.For) ?IntRange {
    if (f.expr.* != .binary or !std.mem.eql(u8, f.expr.binary.operator, "..")) return null;
    if (f.captures.len == 0) return null;
    if (assignsName(f.body, f.captures[0].name)) return null;

    const start = ofExpr(self, f.expr.binary.left) orelse return null;
    const end = ofExpr(self, f.expr.binary.right) orelse return null;
    if (start.min != start.max or end.min != end.max or start.min >= end.min) return null;
    const last = @subWithOverflow(end.min, 1);
    if (last[1] != 0) return null;
    return .{ .min = start.min, .max = last[0] };
}

/// Refine an immutable parameter after the true branch of an early guard
/// terminates. Only direct function-body guards are considered; branch-local
/// facts never leak into sibling control-flow paths.
pub fn refineAfterFalseGuard(self: *Emitter, condition: *ast_mod.Node) !void {
    if (self.scopes.items.len != 2 or condition.* != .binary) return;
    const binary_condition = &condition.binary;
    if (!isOrderedComparison(binary_condition.operator)) return;

    var name_node = binary_condition.left;
    var bound_node = binary_condition.right;
    var op = binary_condition.operator;
    if (!isIdentifier(name_node)) {
        if (!isIdentifier(bound_node)) return;
        name_node = binary_condition.right;
        bound_node = binary_condition.left;
        op = reverseComparison(op);
    }

    const binding = self.lookupBindingOptional(name_node.primary.name) orelse return;
    if (!binding.is_param or binding.assigned or binding.reassigned) return;
    const value_type = try self.valTypeOrClassify(condition, binding.ir_type, binding.display);
    const width = value_type.width orelse return;
    var refined = integerTypeRange(width) orelse return;
    const bound = ofExpr(self, bound_node) orelse return;
    if (bound.min != bound.max) return;

    if (std.mem.eql(u8, op, "<")) {
        refined.min = @max(refined.min, bound.min);
    } else if (std.mem.eql(u8, op, "<=")) {
        const next = @addWithOverflow(bound.min, 1);
        if (next[1] != 0) return;
        refined.min = @max(refined.min, next[0]);
    } else if (std.mem.eql(u8, op, ">")) {
        refined.max = @min(refined.max, bound.max);
    } else if (std.mem.eql(u8, op, ">=")) {
        const previous = @subWithOverflow(bound.max, 1);
        if (previous[1] != 0) return;
        refined.max = @min(refined.max, previous[0]);
    }

    if (self.int_ranges.get(@intFromPtr(binding))) |existing| {
        refined.min = @max(refined.min, existing.min);
        refined.max = @min(refined.max, existing.max);
    }
    if (refined.min <= refined.max) {
        try self.int_ranges.put(@intFromPtr(binding), refined);
    }
}

fn primary(self: *Emitter, p: ast_mod.Primary) ?IntRange {
    if (p.kind != .identifier and p.kind != .register) return null;
    if (self.lookupBindingOptional(p.name)) |binding| {
        return self.int_ranges.get(@intFromPtr(binding));
    }
    if (self.globals.get(p.name)) |global| {
        return self.int_ranges.get(@intFromPtr(global));
    }
    return null;
}

fn isIdentifier(node: *ast_mod.Node) bool {
    return node.* == .primary and
        (node.primary.kind == .identifier or node.primary.kind == .register);
}

fn isOrderedComparison(op: []const u8) bool {
    return std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=");
}

fn reverseComparison(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "<")) return ">";
    if (std.mem.eql(u8, op, "<=")) return ">=";
    if (std.mem.eql(u8, op, ">")) return "<";
    return "<=";
}

fn integerTypeRange(width: widths.Width) ?IntRange {
    return switch (width.concrete()) {
        .i8 => .{ .min = std.math.minInt(i8), .max = std.math.maxInt(i8) },
        .i16 => .{ .min = std.math.minInt(i16), .max = std.math.maxInt(i16) },
        .i32 => .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
        .i64 => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
        .u1 => .{ .min = 0, .max = 1 },
        .u8 => .{ .min = 0, .max = std.math.maxInt(u8) },
        .u16 => .{ .min = 0, .max = std.math.maxInt(u16) },
        .u32 => .{ .min = 0, .max = std.math.maxInt(u32) },
        .u64, .f32, .f64 => null,
        else => null,
    };
}

fn literal(lit: ast_mod.Literal) ?IntRange {
    const value: i64 = switch (lit.literal_type) {
        .number => blk: {
            if (std.mem.indexOfAny(u8, lit.value, ".eE") != null) return null;
            break :blk std.fmt.parseInt(i64, lit.value, 10) catch return null;
        },
        .hex => std.fmt.parseInt(i64, stripPrefix(lit.value), 16) catch return null,
        .octal => std.fmt.parseInt(i64, stripPrefix(lit.value), 8) catch return null,
        .binary => std.fmt.parseInt(i64, stripPrefix(lit.value), 2) catch return null,
        else => return null,
    };
    return IntRange.point(value);
}

fn stripPrefix(value: []const u8) []const u8 {
    return if (value.len > 2 and value[0] == '0') value[2..] else value;
}

fn unary(self: *Emitter, u: *const ast_mod.Unary) ?IntRange {
    if (!std.mem.eql(u8, u.operator, "-")) return null;
    const inner = ofExpr(self, u.arg) orelse return null;
    const min = @subWithOverflow(@as(i64, 0), inner.max);
    const max = @subWithOverflow(@as(i64, 0), inner.min);
    if (min[1] != 0 or max[1] != 0) return null;
    return .{ .min = min[0], .max = max[0] };
}

fn binary(self: *Emitter, b: *const ast_mod.Binary) ?IntRange {
    const lhs = ofExpr(self, b.left) orelse return null;
    const rhs = ofExpr(self, b.right) orelse return null;
    return combine(lhs, rhs, b.operator);
}

fn combine(lhs: IntRange, rhs: IntRange, op: []const u8) ?IntRange {
    if (std.mem.eql(u8, op, "+")) return add(lhs, rhs);
    if (std.mem.eql(u8, op, "-")) return sub(lhs, rhs);
    if (std.mem.eql(u8, op, "*")) return mul(lhs, rhs);
    if (std.mem.eql(u8, op, "%")) return rem(lhs, rhs);
    return null;
}

fn add(lhs: IntRange, rhs: IntRange) ?IntRange {
    const min = @addWithOverflow(lhs.min, rhs.min);
    const max = @addWithOverflow(lhs.max, rhs.max);
    if (min[1] != 0 or max[1] != 0) return null;
    return .{ .min = min[0], .max = max[0] };
}

fn sub(lhs: IntRange, rhs: IntRange) ?IntRange {
    const min = @subWithOverflow(lhs.min, rhs.max);
    const max = @subWithOverflow(lhs.max, rhs.min);
    if (min[1] != 0 or max[1] != 0) return null;
    return .{ .min = min[0], .max = max[0] };
}

fn mul(lhs: IntRange, rhs: IntRange) ?IntRange {
    const products = [_]Product{
        product(lhs.min, rhs.min),
        product(lhs.min, rhs.max),
        product(lhs.max, rhs.min),
        product(lhs.max, rhs.max),
    };
    for (products) |p| if (p.overflow != 0) return null;
    var min = products[0].value;
    var max = products[0].value;
    for (products[1..]) |p| {
        min = @min(min, p.value);
        max = @max(max, p.value);
    }
    return .{ .min = min, .max = max };
}

fn product(a: i64, b: i64) Product {
    const result = @mulWithOverflow(a, b);
    return .{ .value = result[0], .overflow = result[1] };
}

fn rem(lhs: IntRange, rhs: IntRange) ?IntRange {
    if (rhs.min != rhs.max or rhs.min == 0 or rhs.min == std.math.minInt(i64)) return null;
    const magnitude = if (rhs.min < 0) -rhs.min else rhs.min;
    const bound = magnitude - 1;
    if (lhs.min >= 0) return .{ .min = 0, .max = @min(lhs.max, bound) };
    if (lhs.max <= 0) return .{ .min = @max(lhs.min, -bound), .max = 0 };
    return .{ .min = -bound, .max = bound };
}

fn assignsName(node: *ast_mod.Node, name: []const u8) bool {
    return switch (node.*) {
        .assignment => |a| placeHasName(a.left, name) or assignsName(a.right, name),
        .declaration => |d| assignsName(d.value, name),
        .binary => |b| assignsName(b.left, name) or assignsName(b.right, name),
        .unary => |u| (std.mem.eql(u8, u.operator, "&") and placeHasName(u.arg, name)) or assignsName(u.arg, name),
        .call => |c| blk: {
            if (assignsName(c.callee, name)) break :blk true;
            for (c.args) |arg| if (assignsName(arg, name)) break :blk true;
            break :blk false;
        },
        .member => |m| assignsName(m.object, name) or assignsName(m.property, name),
        .index => |i| assignsName(i.object, name) or
            (i.index != null and assignsName(i.index.?, name)) or
            (i.end != null and assignsName(i.end.?, name)),
        .array_literal => |a| blk: {
            for (a.elements) |element| if (assignsName(element, name)) break :blk true;
            break :blk false;
        },
        .block => |b| blk: {
            for (b.statements) |statement| if (assignsName(statement, name)) break :blk true;
            break :blk false;
        },
        .return_expr => |r| r.return_value != null and assignsName(r.return_value.?, name),
        .if_expr => |i| assignsName(i.condition, name) or assignsName(i.body, name) or
            (i.else_body != null and assignsName(i.else_body.?, name)),
        .switch_expr => |s| blk: {
            if (assignsName(s.condition, name)) break :blk true;
            for (s.prongs) |prong| {
                for (prong.patterns) |pattern| if (assignsName(pattern, name)) break :blk true;
                if (assignsName(prong.body, name)) break :blk true;
            }
            break :blk false;
        },
        .for_expr => |f| assignsName(f.expr, name) or assignsName(f.body, name),
        .break_expr => |b| b.value != null and assignsName(b.value.?, name),
        .defer_stmt => |d| assignsName(d.body, name),
        .struct_init => |s| blk: {
            for (s.fields) |field| if (assignsName(field.value, name)) break :blk true;
            break :blk false;
        },
        .try_expr => |t| assignsName(t.expression, name),
        .unwrap_expr => |u| assignsName(u.expression, name),
        .error_expr => |e| blk: {
            for (e.args) |arg| if (assignsName(arg, name)) break :blk true;
            break :blk false;
        },
        .comptime_expr => |c| assignsName(c.expr, name),
        else => false,
    };
}

fn placeHasName(node: *ast_mod.Node, name: []const u8) bool {
    return switch (node.*) {
        .primary => |p| (p.kind == .identifier or p.kind == .register) and std.mem.eql(u8, p.name, name),
        .member => |m| placeHasName(m.object, name),
        .index => |i| placeHasName(i.object, name),
        else => false,
    };
}
