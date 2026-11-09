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
        .member => |m| {
            try markPlaceRootAssigned(self, m.object);
            // Writing through the base also reads it as a place; otherwise an
            // unread pointer/slice parameter gets a pointless `_ = arg;`.
            try preScanExpr(self, m.object);
        },
        .index => |ix| {
            try markPlaceRootAssigned(self, ix.object);
            try preScanExpr(self, ix.object);
            if (ix.index) |v| try preScanExpr(self, v);
            if (ix.end) |v| try preScanExpr(self, v);
        },
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
            if (self.state.type_eq_folds.get(b.left) != null) {
                // Compile-time folded type comparison; neither side is evaluated at runtime.
                return;
            }
            if (std.mem.eql(u8, b.operator, "|>")) {
                // `x |> obj.method` is a method call at emission; mark the
                // receiver mutable just like `obj.method(x)`.
                const callee: *ast_mod.Node = if (b.right.* == .call) b.right.call.callee else b.right;
                if (callee.* == .member and callee.member.property.* == .primary) {
                    const m = &callee.member;
                    if (self.methodTarget(callee) catch null) |t| {
                        if (t.mode == .pointer) try markPlaceRootAssigned(self, m.object);
                    }
                }
            }
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
            if (c.inline_asm) |spec| {
                for (spec.outputs) |output| {
                    if (output.arg_index) |index| try preScanAssignmentTarget(self, c.args[index]);
                }
                for (spec.inputs) |input| try preScanExpr(self, c.args[input.arg_index]);
                return;
            }
            // Compile-time intrinsics (@typeOf, @sizeOf, @nameOf) do not evaluate
            // their operands at runtime, so variables referenced inside them must not
            // be marked as read. @as(T, expr) only evaluates expr at runtime.
            if (c.callee.* == .primary) {
                const name = c.callee.primary.name;
                if (std.mem.eql(u8, name, "@typeOf") or std.mem.eql(u8, name, "@sizeOf") or std.mem.eql(u8, name, "@nameOf")) {
                    return;
                }
                if (std.mem.eql(u8, name, "@as") and c.args.len == 2) {
                    try preScanExpr(self, c.args[1]);
                    return;
                }
            }
            for (c.args) |arg| try preScanExpr(self, arg);
            if (c.callee.* == .member) {
                const m = &c.callee.member;
                if (m.property.* == .primary) {
                    // A pointer-receiver method mutates its receiver in place, so
                    // the local must be emitted as `var` (Zig UB otherwise).
                    if (self.methodTarget(c.callee) catch null) |t| {
                        if (t.mode == .pointer) {
                            try markPlaceRootAssigned(self, m.object);
                            // The receiver is also read by the call; without this an
                            // otherwise-unread parameter would get a pointless discard.
                            try preScanExpr(self, m.object);
                            return;
                        }
                    }
                }
                try preScanExpr(self, m.object);
            }
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
            if (si.type_expr) |te| try preScanExpr(self, te);
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
            const fn_key = self.resolveFunctionValue(d.value, 0) catch null;
            const module_path = if (fn_key == null) self.resolveModuleValue(d.value) else null;
            b.* = .{
                .name = d.name,
                .zig_name = "",
                .display = if (fn_key != null) "func" else if (module_path != null) "module" else self.displayForDeclValue(&d) catch "unknown",
                .ir_type = if (fn_key != null or module_path != null) null else self.declaredIRType(&d),
                .fn_key = fn_key,
                .module_path = module_path,
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
        .continue_expr => |c| {
            if (c.value) |v| try preScanExpr(self, v);
        },
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
