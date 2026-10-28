const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const root_mod = @import("root.zig");
const Emitter = root_mod.Emitter;
const Binding = root_mod.Binding;

pub fn markAssigned(self: *Emitter, name: []const u8) void {
    var i = self.scopes.items.len;
    while (i > 0) {
        i -= 1;
        if (self.scopes.items[i].get(name)) |b| {
            b.assigned = true;
            return;
        }
    }
}

pub fn markReassigned(self: *Emitter, name: []const u8) void {
    var i = self.scopes.items.len;
    while (i > 0) {
        i -= 1;
        if (self.scopes.items[i].get(name)) |b| {
            b.assigned = true;
            b.reassigned = true;
            return;
        }
    }
}

pub fn markRead(self: *Emitter, name: []const u8) void {
    var i = self.scopes.items.len;
    while (i > 0) {
        i -= 1;
        if (self.scopes.items[i].get(name)) |b| {
            b.read = true;
            return;
        }
    }
}

pub fn preScanAssignmentTarget(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) self.markReassigned(p.name);
        },
        .member => |m| try self.markPlaceRootAssigned(m.object),
        .index => |ix| try self.markPlaceRootAssigned(ix.object),
        else => try self.preScanExpr(node),
    }
}

pub fn markPlaceRootAssigned(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) self.markAssigned(p.name);
        },
        .member => |m| try self.markPlaceRootAssigned(m.object),
        .index => |ix| try self.markPlaceRootAssigned(ix.object),
        else => try self.preScanExpr(node),
    }
}

pub fn preScanExpr(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) self.markRead(p.name);
        },
        .literal => {},
        .binary => |b| {
            try self.preScanExpr(b.left);
            try self.preScanExpr(b.right);
        },
        .unary => |u| {
            if (std.mem.eql(u8, u.operator, "&")) {
                try self.markPlaceRootAssigned(u.arg);
            } else {
                try self.preScanExpr(u.arg);
            }
        },
        .assignment => |asn| {
            try self.preScanAssignmentTarget(asn.left);
            try self.preScanExpr(asn.right);
        },
        .call => |c| {
            for (c.args) |arg| try self.preScanExpr(arg);
            if (c.callee.* == .member) try self.preScanExpr(c.callee.member.object);
        },
        .member => |m| {
            try self.preScanExpr(m.object);
            try self.preScanExpr(m.property);
        },
        .index => |ix| {
            try self.preScanExpr(ix.object);
            if (ix.index) |v| try self.preScanExpr(v);
            if (ix.end) |v| try self.preScanExpr(v);
        },
        .array_literal => |al| {
            for (al.elements) |e| try self.preScanExpr(e);
        },
        .try_expr => |t| try self.preScanExpr(t.expression),
        .unwrap_expr => |u| try self.preScanExpr(u.expression),
        .error_expr => |e| {
            for (e.args) |arg| try self.preScanExpr(arg);
        },
        .struct_init => |si| {
            try self.preScanExpr(si.type_expr);
            for (si.fields) |field| try self.preScanExpr(field.value);
        },
        .comptime_expr => |ce| try self.preScanExpr(ce.expr),
        .block, .return_expr, .defer_stmt, .break_expr, .continue_expr, .if_expr, .for_expr, .switch_expr => try self.preScanStmt(node),
        else => {},
    }
}

pub fn preScanStmt(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .declaration => |d| {
            try self.preScanExpr(d.value);
            const b = try self.arena.allocator().create(Binding);
            b.* = .{
                .name = d.name,
                .zig_name = "",
                .display = self.displayForDeclValue(&d) catch "unknown",
            };
            try self.infos.put(node, b);
            try self.scopes.items[self.scopes.items.len - 1].put(d.name, b);
        },
        .block => |b| {
            self.pushScope();
            for (b.statements) |s| {
                try self.preScanStmt(s);
                if (self.stmtTerminates(s)) break;
            }
            self.popScope();
        },
        .return_expr => |r| {
            if (r.return_value) |v| try self.preScanExpr(v);
        },
        .defer_stmt => |d| try self.preScanStmt(d.body),
        .break_expr => |b| {
            if (b.value) |v| try self.preScanExpr(v);
        },
        .continue_expr => {},
        .if_expr => |i| {
            try self.preScanExpr(i.condition);
            if (i.pipe_value) |v| try self.preScanExpr(v);
            try self.preScanStmt(i.body);
            if (i.else_body) |e| try self.preScanStmt(e);
        },
        .for_expr => |f| {
            try self.preScanExpr(f.expr);
            try self.preScanStmt(f.body);
        },
        .switch_expr => |sw| {
            try self.preScanExpr(sw.condition);
            for (sw.prongs) |prong| {
                for (prong.patterns) |p| try self.preScanExpr(p);
                try self.preScanStmt(prong.body);
            }
        },
        .function_decl => {},
        .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
        else => try self.preScanExpr(node),
    }
}

pub fn stmtTerminates(self: *Emitter, node: *ast_mod.Node) bool {
    return switch (node.*) {
        .return_expr, .break_expr, .continue_expr => true,
        .block => |b| blk: {
            if (b.statements.len == 0) break :blk false;
            break :blk self.stmtTerminates(b.statements[b.statements.len - 1]);
        },
        .if_expr => |i| blk: {
            const else_body = i.else_body orelse break :blk false;
            break :blk self.stmtTerminates(i.body) and self.stmtTerminates(else_body);
        },
        .switch_expr => |sw| blk: {
            var has_else = false;
            for (sw.prongs) |prong| {
                if (prong.is_else) has_else = true;
                if (!self.stmtTerminates(prong.body)) break :blk false;
            }
            break :blk has_else and sw.prongs.len > 0;
        },
        else => false,
    };
}
