//! Deep copy of AST subtrees. Strings are shared (never mutated in place);
//! every node and node-holding slice is fresh, so per-node side tables and
//! in-place renames on the copy never touch the original.
const std = @import("std");
const root = @import("root.zig");
const Node = root.Node;

pub const Error = std.mem.Allocator.Error;

pub fn cloneNode(a: std.mem.Allocator, n: *const Node) Error!*Node {
    const out = try a.create(Node);
    out.* = switch (n.*) {
        .literal, .primary, .continue_expr, .extern_decl, .enum_decl, .error_decl => n.*,
        .declaration => |d| blk: {
            var c = d;
            c.value = try cloneNode(a, d.value);
            c.type_annotation = try cloneOpt(a, d.type_annotation);
            break :blk .{ .declaration = c };
        },
        .binary => |b| blk: {
            var c = b;
            c.left = try cloneNode(a, b.left);
            c.right = try cloneNode(a, b.right);
            break :blk .{ .binary = c };
        },
        .unary => |u| blk: {
            var c = u;
            c.arg = try cloneNode(a, u.arg);
            break :blk .{ .unary = c };
        },
        .assignment => |as| blk: {
            var c = as;
            c.left = try cloneNode(a, as.left);
            c.right = try cloneNode(a, as.right);
            break :blk .{ .assignment = c };
        },
        .call => |cl| blk: {
            var c = cl;
            c.callee = try cloneNode(a, cl.callee);
            c.args = try cloneSlice(a, cl.args);
            break :blk .{ .call = c };
        },
        .member => |m| blk: {
            var c = m;
            c.object = try cloneNode(a, m.object);
            c.property = try cloneNode(a, m.property);
            break :blk .{ .member = c };
        },
        .index => |ix| blk: {
            var c = ix;
            c.object = try cloneNode(a, ix.object);
            c.index = try cloneOpt(a, ix.index);
            c.end = try cloneOpt(a, ix.end);
            c.type_annotation = try cloneOpt(a, ix.type_annotation);
            break :blk .{ .index = c };
        },
        .array_literal => |al| blk: {
            var c = al;
            c.elements = try cloneSlice(a, al.elements);
            break :blk .{ .array_literal = c };
        },
        .function_decl => |f| blk: {
            var c = f;
            c.params = try cloneNode(a, f.params);
            c.body = try cloneNode(a, f.body);
            c.return_type = try cloneOpt(a, f.return_type);
            break :blk .{ .function_decl = c };
        },
        .params => |p| blk: {
            var c = p;
            const ps = try a.alloc(root.Param, p.params.len);
            for (p.params, ps) |src, *dst| {
                dst.* = src;
                dst.type_annotation = try cloneOpt(a, src.type_annotation);
            }
            c.params = ps;
            break :blk .{ .params = c };
        },
        .block => |b| blk: {
            var c = b;
            c.statements = try cloneSlice(a, b.statements);
            break :blk .{ .block = c };
        },
        .return_expr => |r| blk: {
            var c = r;
            c.return_value = try cloneOpt(a, r.return_value);
            break :blk .{ .return_expr = c };
        },
        .if_expr => |i| blk: {
            var c = i;
            c.condition = try cloneNode(a, i.condition);
            c.pipe_value = try cloneOpt(a, i.pipe_value);
            c.body = try cloneNode(a, i.body);
            c.else_body = try cloneOpt(a, i.else_body);
            break :blk .{ .if_expr = c };
        },
        .switch_expr => |sw| blk: {
            var c = sw;
            c.condition = try cloneNode(a, sw.condition);
            const prongs = try a.alloc(root.SwitchProng, sw.prongs.len);
            for (sw.prongs, prongs) |src, *dst| {
                dst.* = src;
                dst.patterns = try cloneSlice(a, src.patterns);
                dst.body = try cloneNode(a, src.body);
            }
            c.prongs = prongs;
            break :blk .{ .switch_expr = c };
        },
        .for_expr => |f| blk: {
            var c = f;
            c.expr = try cloneNode(a, f.expr);
            c.body = try cloneNode(a, f.body);
            break :blk .{ .for_expr = c };
        },
        .break_expr => |br| blk: {
            var c = br;
            c.value = try cloneOpt(a, br.value);
            break :blk .{ .break_expr = c };
        },
        .defer_stmt => |d| blk: {
            var c = d;
            c.body = try cloneNode(a, d.body);
            break :blk .{ .defer_stmt = c };
        },
        .struct_decl => |s| blk: {
            var c = s;
            const fields = try a.alloc(root.StructField, s.fields.len);
            for (s.fields, fields) |src, *dst| {
                dst.* = src;
                dst.type_annotation = try cloneOpt(a, src.type_annotation);
            }
            c.fields = fields;
            c.methods = try cloneSlice(a, s.methods);
            break :blk .{ .struct_decl = c };
        },
        .type_decl => |td| blk: {
            var c = td;
            c.type_expr = try cloneNode(a, td.type_expr);
            break :blk .{ .type_decl = c };
        },
        .struct_init => |s| blk: {
            var c = s;
            c.type_expr = try cloneNode(a, s.type_expr);
            const fields = try a.alloc(root.StructFieldInit, s.fields.len);
            for (s.fields, fields) |src, *dst| {
                dst.* = src;
                dst.value = try cloneNode(a, src.value);
            }
            c.fields = fields;
            break :blk .{ .struct_init = c };
        },
        .try_expr => |t| blk: {
            var c = t;
            c.expression = try cloneNode(a, t.expression);
            break :blk .{ .try_expr = c };
        },
        .unwrap_expr => |u| blk: {
            var c = u;
            c.expression = try cloneNode(a, u.expression);
            break :blk .{ .unwrap_expr = c };
        },
        .error_expr => |e| blk: {
            var c = e;
            c.args = try cloneSlice(a, e.args);
            break :blk .{ .error_expr = c };
        },
        .comptime_expr => |ce| blk: {
            var c = ce;
            c.expr = try cloneNode(a, ce.expr);
            break :blk .{ .comptime_expr = c };
        },
        .array_type => |at| blk: {
            var c = at;
            c.elem = try cloneNode(a, at.elem);
            break :blk .{ .array_type = c };
        },
        .tuple_type => |t| blk: {
            var c = t;
            c.elems = try cloneSlice(a, t.elems);
            break :blk .{ .tuple_type = c };
        },
        .union_type => |u| blk: {
            var c = u;
            c.left = try cloneNode(a, u.left);
            c.right = try cloneNode(a, u.right);
            break :blk .{ .union_type = c };
        },
        .intersection_type => |ix| blk: {
            var c = ix;
            c.left = try cloneNode(a, ix.left);
            c.right = try cloneNode(a, ix.right);
            break :blk .{ .intersection_type = c };
        },
        .pointer_type => |p| blk: {
            var c = p;
            c.elem = try cloneNode(a, p.elem);
            break :blk .{ .pointer_type = c };
        },
        .func_type => |f| blk: {
            var c = f;
            c.params = try cloneSlice(a, f.params);
            c.return_type = try cloneOpt(a, f.return_type);
            break :blk .{ .func_type = c };
        },
        .shape_type => |s| blk: {
            var c = s;
            const fields = try a.alloc(root.ShapeField, s.fields.len);
            for (s.fields, fields) |src, *dst| {
                dst.* = src;
                dst.type_annotation = try cloneOpt(a, src.type_annotation);
            }
            c.fields = fields;
            break :blk .{ .shape_type = c };
        },
    };
    return out;
}

fn cloneOpt(a: std.mem.Allocator, n: ?*Node) Error!?*Node {
    return if (n) |x| try cloneNode(a, x) else null;
}

fn cloneSlice(a: std.mem.Allocator, nodes: []*Node) Error![]*Node {
    const out = try a.alloc(*Node, nodes.len);
    for (nodes, out) |src, *dst| dst.* = try cloneNode(a, src);
    return out;
}
