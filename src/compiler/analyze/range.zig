const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const ir = @import("../typecheck/ir.zig");
const widths = @import("../widths.zig");

pub const IntRange = struct {
    min: i64,
    max: i64,

    pub fn point(v: i64) IntRange {
        return .{ .min = v, .max = v };
    }
};

const Product = struct {
    value: i64,
    overflow: u1,
};

pub const RangeAnalyzer = struct {
    state: *state_mod.CompilerState,
    allocator: std.mem.Allocator,
    globals: std.StringHashMap(IntRange),
    scopes: std.ArrayList(std.StringHashMap(IntRange)),

    pub fn init(state: *state_mod.CompilerState) RangeAnalyzer {
        return .{
            .state = state,
            .allocator = state.allocator,
            .globals = std.StringHashMap(IntRange).init(state.allocator),
            .scopes = .empty,
        };
    }

    pub fn deinit(self: *RangeAnalyzer) void {
        var it = self.globals.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, "$")) {
                self.allocator.free(k.*);
            }
        }
        self.globals.deinit();
        for (self.scopes.items) |*s| {
            s.deinit();
        }
        self.scopes.deinit(self.allocator);
    }

    fn pushScope(self: *RangeAnalyzer) !void {
        try self.scopes.append(self.allocator, std.StringHashMap(IntRange).init(self.allocator));
    }

    fn popScope(self: *RangeAnalyzer) void {
        if (self.scopes.items.len > 0) {
            var s = self.scopes.pop().?;
            s.deinit();
        }
    }

    fn putInCurrentScope(self: *RangeAnalyzer, name: []const u8, range: IntRange) !void {
        if (self.scopes.items.len == 0) return;
        const current = &self.scopes.items[self.scopes.items.len - 1];
        try current.put(name, range);
    }

    fn lookup(self: *RangeAnalyzer, name: []const u8) ?IntRange {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.get(name)) |r| return r;
            if (std.mem.startsWith(u8, name, "$")) {
                if (scope.get(name[1..])) |r| return r;
            } else {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "${s}", .{name})) |k| {
                    if (scope.get(k)) |r| return r;
                } else |_| {}
            }
        }
        if (self.globals.get(name)) |r| return r;
        if (std.mem.startsWith(u8, name, "$")) {
            if (self.globals.get(name[1..])) |r| return r;
        } else {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "${s}", .{name})) |k| {
                if (self.globals.get(k)) |r| return r;
            } else |_| {}
        }
        return null;
    }

    pub fn ofExpr(self: *RangeAnalyzer, node: *ast.Node) ?IntRange {
        return switch (node.*) {
            .literal => |lit| literal(lit),
            .primary => |p| if (p.kind == .identifier or p.kind == .register) self.lookup(p.name) else null,
            .unary => |u| self.unary(&u),
            .binary => |b| self.binary(&b),
            .comptime_expr => |ce| self.ofExpr(ce.expr),
            else => null,
        };
    }

    fn unary(self: *RangeAnalyzer, u: *const ast.Unary) ?IntRange {
        if (!std.mem.eql(u8, u.operator, "-")) return null;
        const inner = self.ofExpr(u.arg) orelse return null;
        const min = @subWithOverflow(@as(i64, 0), inner.max);
        const max = @subWithOverflow(@as(i64, 0), inner.min);
        if (min[1] != 0 or max[1] != 0) return null;
        return .{ .min = min[0], .max = max[0] };
    }

    fn binary(self: *RangeAnalyzer, b: *const ast.Binary) ?IntRange {
        const lhs = self.ofExpr(b.left) orelse return null;
        const rhs = self.ofExpr(b.right) orelse return null;
        return combine(lhs, rhs, b.operator);
    }

    fn resultFits(self: *RangeAnalyzer, node: *ast.Node, left: *ast.Node, right: *ast.Node, op: []const u8) bool {
        const w = self.irTypeWidth(left) orelse self.irTypeWidth(node) orelse return false;
        const lhs = self.ofExpr(left) orelse return false;
        const rhs = self.ofExpr(right) orelse return false;
        const result = combine(lhs, rhs, op) orelse return false;
        return widths.i64Fits(w, result.min) and widths.i64Fits(w, result.max);
    }

    fn irTypeWidth(self: *RangeAnalyzer, node: *ast.Node) ?widths.Width {
        const t = self.state.type_ir_of_results.get(node) orelse return null;
        return switch (ir.peelDefined(t)) {
            .i64, .int_lit => .i64,
            .i32 => .i32,
            .i16 => .i16,
            .i8 => .i8,
            .u32 => .u32,
            .u16 => .u16,
            .u8 => .u8,
            .u1, .bool_lit => .u1,
            else => null,
        };
    }

    fn refineAfterFalseGuard(self: *RangeAnalyzer, condition: *ast.Node) !void {
        if (condition.* != .binary) return;
        const b = &condition.binary;
        if (!isOrderedComparison(b.operator)) return;

        var name_node = b.left;
        var bound_node = b.right;
        var op = b.operator;
        if (!isIdentifier(name_node)) {
            if (!isIdentifier(bound_node)) return;
            name_node = b.right;
            bound_node = b.left;
            op = reverseComparison(op);
        }

        const name = name_node.primary.name;
        var refined = self.lookup(name) orelse return;
        const bound = self.ofExpr(bound_node) orelse return;
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

        if (refined.min <= refined.max) {
            try self.putInCurrentScope(name, refined);
        }
    }

    fn analyzeStatement(self: *RangeAnalyzer, stmt: *ast.Node) anyerror!void {
        switch (stmt.*) {
            .block => |b| {
                try self.pushScope();
                defer self.popScope();
                for (b.statements) |s| {
                    try self.analyzeStatement(s);
                }
            },
            .declaration => |d| {
                if (d.is_const) {
                    if (self.ofExpr(d.value)) |r| {
                        try self.putInCurrentScope(d.name, r);
                    }
                }
                try self.analyzeExpr(d.value);
            },
            .assignment => |asn| {
                try self.analyzeExpr(asn.left);
                try self.analyzeExpr(asn.right);
            },
            .if_expr => |ife| {
                try self.analyzeExpr(ife.condition);
                try self.analyzeStatement(ife.body);
                if (ife.else_body) |eb| {
                    try self.analyzeStatement(eb);
                }
            },
            .for_expr => |f| {
                try self.analyzeExpr(f.expr);
                try self.pushScope();
                defer self.popScope();
                if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..") and f.captures.len > 0) {
                    const start = self.ofExpr(f.expr.binary.left);
                    const end = self.ofExpr(f.expr.binary.right);
                    if (start != null and end != null and start.?.min == start.?.max and end.?.min == end.?.max and start.?.min < end.?.max) {
                        const last = @subWithOverflow(end.?.min, 1);
                        if (last[1] == 0) {
                            try self.putInCurrentScope(f.captures[0].name, .{ .min = start.?.min, .max = last[0] });
                        }
                    }
                }
                try self.analyzeStatement(f.body);
            },
            .return_expr => |r| {
                if (r.return_value) |rv| try self.analyzeExpr(rv);
            },
            .switch_expr => |sw| {
                try self.analyzeExpr(sw.condition);
                for (sw.prongs) |p| {
                    for (p.patterns) |pat| try self.analyzeExpr(pat);
                    try self.analyzeStatement(p.body);
                }
            },
            .defer_stmt => |d| try self.analyzeStatement(d.body),
            else => try self.analyzeExpr(stmt),
        }
    }

    fn analyzeExpr(self: *RangeAnalyzer, expr: *ast.Node) anyerror!void {
        switch (expr.*) {
            .binary => |b| {
                try self.analyzeExpr(b.left);
                try self.analyzeExpr(b.right);
                if (std.mem.eql(u8, b.operator, "+") or std.mem.eql(u8, b.operator, "-") or std.mem.eql(u8, b.operator, "*")) {
                    if (self.resultFits(expr, b.left, b.right, b.operator)) {
                        try self.state.proven_arithmetic.put(expr, {});
                    }
                }
            },
            .unary => |u| try self.analyzeExpr(u.arg),
            .call => |c| {
                try self.analyzeExpr(c.callee);
                for (c.args) |a| try self.analyzeExpr(a);
            },
            .member => |m| try self.analyzeExpr(m.object),
            .index => |ix| {
                try self.analyzeExpr(ix.object);
                if (ix.index) |i| try self.analyzeExpr(i);
                if (ix.end) |e| try self.analyzeExpr(e);
            },
            .array_literal => |al| {
                for (al.elements) |el| try self.analyzeExpr(el);
            },
            .struct_init => |si| {
                for (si.fields) |f| try self.analyzeExpr(f.value);
            },
            .unwrap_expr => |u| try self.analyzeExpr(u.expression),
            .try_expr => |t| try self.analyzeExpr(t.expression),
            .error_expr => |e| {
                for (e.args) |a| try self.analyzeExpr(a);
            },
            .comptime_expr => |ce| try self.analyzeExpr(ce.expr),
            else => {},
        }
    }

    pub fn analyzeFunction(self: *RangeAnalyzer, f: *const ast.FunctionDecl) anyerror!void {
        try self.pushScope();
        defer self.popScope();

        if (f.params.* == .params) {
            for (f.params.params.params) |*p| {
                const facts = self.state.param_facts.get(p) orelse state_mod.BindingFacts{};
                if (facts.assigned or facts.reassigned) continue;
                if (p.type_annotation) |ta| {
                    if (integerTypeRangeFromAnnotation(self.state, ta)) |r| {
                        try self.putInCurrentScope(p.name, r);
                    }
                }
            }
        }

        const block = switch (f.body.*) {
            .block => |b| b,
            else => return,
        };
        for (block.statements) |s| {
            try self.analyzeStatement(s);
            if (s.* == .if_expr) {
                const ife = &s.if_expr;
                if (ife.else_body == null and (self.state.terminates.get(ife.body) orelse false)) {
                    try self.refineAfterFalseGuard(ife.condition);
                }
            }
        }
    }
};

pub fn analyze(state: *state_mod.CompilerState, doc: *ast.Document) anyerror!void {
    var analyzer = RangeAnalyzer.init(state);
    defer analyzer.deinit();

    // Pass 1: Record top-level @const declarations into globals
    for (doc.statements) |s| {
        if (s.* == .declaration and s.declaration.is_const) {
            if (analyzer.ofExpr(s.declaration.value)) |r| {
                try analyzer.globals.put(s.declaration.name, r);
                if (!std.mem.startsWith(u8, s.declaration.name, "$")) {
                    const dollar = try std.fmt.allocPrint(analyzer.allocator, "${s}", .{s.declaration.name});
                    try analyzer.globals.put(dollar, r);
                }
            }
        }
    }
    for (state.module_docs.items) |mdoc| {
        if (mdoc == doc or (doc.path.len > 0 and std.mem.eql(u8, mdoc.path, doc.path))) continue;
        for (mdoc.statements) |s| {
            if (s.* == .declaration and s.declaration.is_const) {
                if (analyzer.ofExpr(s.declaration.value)) |r| {
                    try analyzer.globals.put(s.declaration.name, r);
                    if (!std.mem.startsWith(u8, s.declaration.name, "$")) {
                        const dollar = try std.fmt.allocPrint(analyzer.allocator, "${s}", .{s.declaration.name});
                        try analyzer.globals.put(dollar, r);
                    }
                }
            }
        }
    }

    // Pass 2: Analyze functions
    var it = state.functions.valueIterator();
    while (it.next()) |def| {
        if (def.node.* == .function_decl) {
            try analyzer.analyzeFunction(&def.node.function_decl);
        }
    }

    // Pass 3: Analyze top-level statements
    try analyzer.pushScope();
    defer analyzer.popScope();
    for (doc.statements) |s| {
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => continue,
            else => try analyzer.analyzeStatement(s),
        }
    }
    for (state.module_docs.items) |mdoc| {
        if (mdoc == doc or (doc.path.len > 0 and std.mem.eql(u8, mdoc.path, doc.path))) continue;
        for (mdoc.statements) |s| {
            switch (s.*) {
                .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => continue,
                else => try analyzer.analyzeStatement(s),
            }
        }
    }
}

fn integerTypeRangeFromAnnotation(state: *state_mod.CompilerState, node: *ast.Node) ?IntRange {
    if (state.type_ir_of_results.get(node)) |t| {
        return integerTypeRangeFromIR(t);
    }
    return switch (node.*) {
        .primary => |p| if (p.kind == .identifier) blk: {
            if (std.mem.eql(u8, p.name, "int") or std.mem.eql(u8, p.name, "i64"))
                break :blk integerTypeRange(widths.Width.i64)
            else if (std.mem.eql(u8, p.name, "i32"))
                break :blk integerTypeRange(widths.Width.i32)
            else if (std.mem.eql(u8, p.name, "i16"))
                break :blk integerTypeRange(widths.Width.i16)
            else if (std.mem.eql(u8, p.name, "i8"))
                break :blk integerTypeRange(widths.Width.i8)
            else if (std.mem.eql(u8, p.name, "u32"))
                break :blk integerTypeRange(widths.Width.u32)
            else if (std.mem.eql(u8, p.name, "u16"))
                break :blk integerTypeRange(widths.Width.u16)
            else if (std.mem.eql(u8, p.name, "u8") or std.mem.eql(u8, p.name, "byte"))
                break :blk integerTypeRange(widths.Width.u8)
            else if (std.mem.eql(u8, p.name, "u1") or std.mem.eql(u8, p.name, "bool") or std.mem.eql(u8, p.name, "boolean"))
                break :blk integerTypeRange(widths.Width.u1)
            else
                break :blk null;
        } else null,
        else => null,
    };
}

fn integerTypeRangeFromIR(t: ir.Type) ?IntRange {
    return switch (ir.peelDefined(t)) {
        .i64, .int_lit => integerTypeRange(widths.Width.i64),
        .i32 => integerTypeRange(widths.Width.i32),
        .i16 => integerTypeRange(widths.Width.i16),
        .i8 => integerTypeRange(widths.Width.i8),
        .u32 => integerTypeRange(widths.Width.u32),
        .u16 => integerTypeRange(widths.Width.u16),
        .u8 => integerTypeRange(widths.Width.u8),
        .u1, .bool_lit => integerTypeRange(widths.Width.u1),
        else => null,
    };
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

fn literal(lit: ast.Literal) ?IntRange {
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

fn isIdentifier(node: *ast.Node) bool {
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
