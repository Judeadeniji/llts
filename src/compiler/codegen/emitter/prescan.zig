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
            if (p.kind == .identifier or p.kind == .register) markReassigned(self, p.name);
        },
        .member => |m| try markPlaceRootAssigned(self, m.object),
        .index => |ix| try markPlaceRootAssigned(self, ix.object),
        else => try preScanExpr(self, node),
    }
}

pub fn markPlaceRootAssigned(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) markAssigned(self, p.name);
        },
        .member => |m| try markPlaceRootAssigned(self, m.object),
        .index => |ix| try markPlaceRootAssigned(self, ix.object),
        else => try preScanExpr(self, node),
    }
}

pub fn preScanExpr(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) markRead(self, p.name);
        },
        .literal => {},
        .binary => |b| {
            try preScanExpr(self, b.left);
            try preScanExpr(self, b.right);
        },
        .unary => |u| {
            if (std.mem.eql(u8, u.operator, "&")) {
                try markPlaceRootAssigned(self, u.arg);
            } else {
                try preScanExpr(self, u.arg);
            }
        },
        .assignment => |asn| {
            try preScanAssignmentTarget(self, asn.left);
            try preScanExpr(self, asn.right);
        },
        .call => |c| {
            for (c.args) |arg| try preScanExpr(self, arg);
            if (c.callee.* == .member) try preScanExpr(self, c.callee.member.object);
        },
        .member => |m| {
            try preScanExpr(self, m.object);
            try preScanExpr(self, m.property);
        },
        .index => |ix| {
            try preScanExpr(self, ix.object);
            if (ix.index) |v| try preScanExpr(self, v);
            if (ix.end) |v| try preScanExpr(self, v);
        },
        .array_literal => |al| {
            for (al.elements) |e| try preScanExpr(self, e);
        },
        .try_expr => |t| try preScanExpr(self, t.expression),
        .unwrap_expr => |u| try preScanExpr(self, u.expression),
        .error_expr => |e| {
            for (e.args) |arg| try preScanExpr(self, arg);
        },
        .struct_init => |si| {
            try preScanExpr(self, si.type_expr);
            for (si.fields) |field| try preScanExpr(self, field.value);
        },
        .comptime_expr => |ce| try preScanExpr(self, ce.expr),
        .block, .return_expr, .defer_stmt, .break_expr, .continue_expr, .if_expr, .for_expr, .switch_expr => try preScanStmt(self, node),
        else => {},
    }
}

pub fn preScanStmt(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    switch (node.*) {
        .declaration => |d| {
            try preScanExpr(self, d.value);
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
                try preScanStmt(self, s);
                if (stmtTerminates(self, s)) break;
            }
            self.popScope();
        },
        .return_expr => |r| {
            if (r.return_value) |v| try preScanExpr(self, v);
        },
        .defer_stmt => |d| try preScanStmt(self, d.body),
        .break_expr => |b| {
            if (b.value) |v| try preScanExpr(self, v);
        },
        .continue_expr => {},
        .if_expr => |i| {
            try preScanExpr(self, i.condition);
            if (i.pipe_value) |v| try preScanExpr(self, v);
            try preScanStmt(self, i.body);
            if (i.else_body) |e| try preScanStmt(self, e);
        },
        .for_expr => |f| {
            try preScanExpr(self, f.expr);
            try preScanStmt(self, f.body);
        },
        .switch_expr => |sw| {
            try preScanExpr(self, sw.condition);
            for (sw.prongs) |prong| {
                for (prong.patterns) |p| try preScanExpr(self, p);
                try preScanStmt(self, prong.body);
            }
        },
        .function_decl => {},
        .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
        else => try preScanExpr(self, node),
    }
}

pub fn stmtTerminates(self: *Emitter, node: *ast_mod.Node) bool {
    return switch (node.*) {
        .return_expr, .break_expr, .continue_expr => true,
        .block => |b| blk: {
            if (b.statements.len == 0) break :blk false;
            break :blk stmtTerminates(self, b.statements[b.statements.len - 1]);
        },
        .if_expr => |i| blk: {
            const else_body = i.else_body orelse break :blk false;
            break :blk stmtTerminates(self, i.body) and stmtTerminates(self, else_body);
        },
        .switch_expr => |sw| blk: {
            var has_else = false;
            for (sw.prongs) |prong| {
                if (prong.is_else) has_else = true;
                if (!stmtTerminates(self, prong.body)) break :blk false;
            }
            break :blk has_else and sw.prongs.len > 0;
        },
        else => false,
    };
}
