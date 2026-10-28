const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const root_mod = @import("root.zig");
const Emitter = root_mod.Emitter;
const ValType = root_mod.ValType;
const Binding = root_mod.Binding;
const BreakTarget = root_mod.BreakTarget;
const LoopTarget = root_mod.LoopTarget;

pub fn emitAssignment(self: *Emitter, node: *ast_mod.Node, asn: *const ast_mod.Assignment) !void {
    if (!std.mem.eql(u8, asn.operator, "=")) {
        return self.failAt(node, "native backend (Phase 3) does not support '{s}' yet", .{asn.operator});
    }
    switch (asn.left.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) {
                return self.failAt(asn.left, "native backend only supports assigning to names", .{});
            }
            const target = try self.lookupBinding(asn.left, p.name);
            const value_t = try self.valueType(asn.right);
            if (value_t.may_error) {
                return self.failAt(asn.right, "error-union value must be handled with '?' before assignment", .{});
            }
            const vt = try self.classify(node, target.display);
            try self.requireValueType(node, vt);
            const rhs = try self.emitValueCoerced(asn.right, vt);
            try self.writeIndent();
            try self.writer.print("{s} = {s};\n", .{ target.zig_name, rhs });
        },
        .member => |*m| {
            const target = (try self.resolveMemberField(asn.left, m)) orelse {
                return self.failAt(asn.left, "native backend only supports assigning to struct fields", .{});
            };
            const field = target.info.fields[target.index];
            try self.requireValueType(asn.left, field.vt);
            const rhs = try self.emitValueCoerced(asn.right, field.vt);
            const lvalue = try self.emitPlaceLvalue(asn.left);
            try self.writeIndent();
            try self.writer.print("{s} = {s};\n", .{ lvalue, rhs });
        },
        .index => |*ix| try self.emitIndexAssignment(node, asn, ix),
        else => return self.failAt(asn.left, "native backend only supports assigning to names, fields, or array elements", .{}),
    }
}

pub fn emitIndexAssignment(self: *Emitter, node: *ast_mod.Node, asn: *const ast_mod.Assignment, ix: *const ast_mod.Index) !void {
    if (ix.is_slice) {
        return self.failAt(node, "Cannot assign to a slice view", .{});
    }
    const a = self.arena.allocator();
    var obj_t = try self.valueType(ix.object);
    var obj_code = try self.emitPlaceLvalue(ix.object);
    if (obj_t.kind == .pointer) {
        const payload = obj_t.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{obj_t.display});
        obj_t = payload.*;
        obj_code = try std.fmt.allocPrint(a, "({s}).*", .{obj_code});
    }
    const word: []const u8 = switch (obj_t.kind) {
        .array => "Array",
        .slice => "Slice",
        else => return self.failAt(node, "native backend cannot assign into '{s}' yet", .{obj_t.display}),
    };
    const use: []const u8 = if (obj_t.kind == .slice) "slice" else "arr";
    const index_node = ix.index orelse return self.failAt(node, "expected index expression", .{});
    const elem_t = obj_t.elem orelse {
        return self.failAt(node, "native backend cannot determine the element type of '{s}'", .{obj_t.display});
    };
    const rhs = try self.emitValueCoerced(asn.right, elem_t.*);
    const index_code = try self.emitI64Operand(index_node);

    self.counter += 1;
    const id = self.counter;
    const idx_name = try std.fmt.allocPrint(a, "lls_set_idx_{d}", .{id});
    const rhs_name = try std.fmt.allocPrint(a, "lls_set_rhs_{d}", .{id});
    const fmt = try std.fmt.allocPrint(a, "{s} index out of bounds: {{d}} (len {{d}}); use len({s})", .{ word, use });

    try self.writeIndent();
    try self.writer.print("const {s}: i64 = {s};\n", .{ idx_name, index_code });
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ rhs_name, elem_t.zig, rhs });
    try self.writeIndent();
    try self.writer.print("if ({s} < 0 or {s} >= @as(i64, @intCast(({s}).len))) return rt.io.fail({s}, .{{ {s}, @as(i64, @intCast(({s}).len)) }});\n", .{
        idx_name, idx_name, obj_code, try self.zigString(fmt), idx_name, obj_code,
    });
    try self.writeIndent();
    try self.writer.print("{s}[@intCast({s})] = {s};\n", .{ obj_code, idx_name, rhs_name });
}

pub fn emitPlaceLvalue(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) {
                return self.failAt(node, "native backend only supports assigning to names", .{});
            }
            const target = try self.lookupBinding(node, p.name);
            return target.zig_name;
        },
        .member => |m| {
            const target = (try self.resolveMemberField(node, &m)) orelse {
                return self.failAt(node, "native backend only supports assigning to struct fields", .{});
            };
            const field = target.info.fields[target.index];
            const base = try self.emitPlaceLvalue(m.object);
            const obj_t = try self.valueType(m.object);
            const deref: []const u8 = if (obj_t.kind == .pointer) ".*" else "";
            return std.fmt.allocPrint(a, "({s}){s}.{s}", .{ base, deref, field.zig_name });
        },
        .index => |ix| {
            if (ix.is_slice) {
                return self.failAt(node, "Cannot assign to a slice view", .{});
            }
            var obj_t = try self.valueType(ix.object);
            if (obj_t.kind == .pointer) {
                const payload = obj_t.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{obj_t.display});
                obj_t = payload.*;
            }
            const word: []const u8 = switch (obj_t.kind) {
                .array => "Array",
                .slice => "Slice",
                else => return self.failAt(node, "native backend cannot assign into '{s}' yet", .{obj_t.display}),
            };
            const use: []const u8 = if (obj_t.kind == .slice) "slice" else "arr";
            const index_node = ix.index orelse return self.failAt(node, "expected index expression", .{});
            const index_code = try self.emitI64Operand(index_node);
            const obj_t_full = try self.valueType(ix.object);
            var base = try self.emitPlaceLvalue(ix.object);
            if (obj_t_full.kind == .pointer) {
                base = try std.fmt.allocPrint(a, "({s}).*", .{base});
            }
            self.counter += 1;
            const id = self.counter;
            const idx_name = try std.fmt.allocPrint(a, "lls_place_idx_{d}", .{id});
            const fmt = try std.fmt.allocPrint(a, "{s} index out of bounds: {{d}} (len {{d}}); use len({s})", .{ word, use });
            try self.writeIndent();
            try self.writer.print("const {s}: i64 = {s};\n", .{ idx_name, index_code });
            try self.writeIndent();
            try self.writer.print("if ({s} < 0 or {s} >= @as(i64, @intCast(({s}).len))) return rt.io.fail({s}, .{{ {s}, @as(i64, @intCast(({s}).len)) }});\n", .{
                idx_name, idx_name, base, try self.zigString(fmt), idx_name, base,
            });
            return std.fmt.allocPrint(a, "{s}[@intCast({s})]", .{ base, idx_name });
        },
        else => return self.failAt(node, "native backend cannot assign to this expression yet", .{}),
    }
}

pub fn emitBoolCondition(self: *Emitter, node: *ast_mod.Node, what: []const u8) ![]const u8 {
    const t = try self.valueType(node);
    if (t.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' before use as a {s} condition", .{what});
    }
    if (t.kind != .bool) {
        return self.failAt(node, "{s} condition must be boolean, got '{s}'", .{ what, t.display });
    }
    return self.emitExpr(node);
}

pub fn emitBreak(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Break) !void {
    if (b.value) |value| {
        const target = self.findBreakTarget(b.label) orelse {
            if (b.label) |label| {
                return self.failAt(node, "native backend cannot find value expression with label '{s}'", .{label});
            }
            return self.failAt(node, "break with a value requires a value-producing @if, @switch, or labeled block", .{});
        };
        // The value may itself be a value-producing expression, which can
        // reallocate `break_targets`; capture these before emitting it.
        const target_type = target.value_type;
        const zig_label = target.zig_label;
        const target_depth = target.scope_depth;
        const code = try self.emitStrongCoercion(value, target_type);
        self.counter += 1;
        const tmp = try std.fmt.allocPrint(self.arena.allocator(), "lls_brk_{d}", .{self.counter});
        try self.writeIndent();
        try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, target_type.zig, code });
        try self.emitDeferredFromDepth(target_depth);
        try self.writeIndent();
        try self.writer.print("break :{s} {s};\n", .{ zig_label, tmp });
        return;
    }

    if (b.label) |label| {
        if (self.findBreakTarget(label) != null) {
            return self.failAt(node, "break to a value expression requires a value", .{});
        }
    }
    const target = self.findLoopTarget(b.label) orelse {
        if (b.label) |label| {
            return self.failAt(node, "native backend cannot find loop with label '{s}'", .{label});
        }
        return self.failAt(node, "break outside a loop requires a value-producing expression", .{});
    };
    try self.emitDeferredFromDepth(target.scope_depth);
    try self.writeIndent();
    if (target.zig_label) |zig_label| {
        try self.writer.print("break :{s};\n", .{zig_label});
    } else {
        try self.writer.writeAll("break;\n");
    }
}

pub fn emitCondFor(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) !void {
    if (f.captures.len > 0) return self.emitCaptureCondFor(node, f);
    const a = self.arena.allocator();
    const condition = try self.emitBoolCondition(f.expr, "@for");
    self.counter += 1;
    const zig_label: ?[]const u8 = if (f.label) |label|
        if (self.loopLabelUsed(f.body, label))
            try std.fmt.allocPrint(a, "lls_loop_{d}", .{self.counter})
        else
            null
    else
        null;
    try self.loop_targets.append(a, .{ .label = f.label, .zig_label = zig_label, .scope_depth = self.scopes.items.len });
    defer _ = self.loop_targets.pop();

    try self.writeIndent();
    if (zig_label) |label| try self.writer.print("{s}: ", .{label});
    try self.writer.print("while ({s}) {{\n", .{condition});
    self.indent += 1;
    self.pushScope();
    defer self.popScope();
    const body = try self.forBody(node, f);
    try self.emitStatements(body.statements);
    try self.emitDeferredAtScopeEnd(body.statements);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
}

pub fn emitCaptureCondFor(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) !void {
    const a = self.arena.allocator();
    const cond_t = try self.valueType(f.expr);
    if (cond_t.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' before iteration", .{});
    }
    if (cond_t.kind != .optional) {
        return self.failAt(node, "@for capture requires an optional condition, got '{s}'", .{cond_t.display});
    }
    const payload = cond_t.payload orelse {
        return self.failAt(node, "native backend cannot determine the optional payload type", .{});
    };

    self.counter += 1;
    const id = self.counter;
    const tmp_name = try std.fmt.allocPrint(a, "lls_foropt_{d}", .{id});
    const cap_name = try self.localName(f.captures[0].name);
    const zig_label: ?[]const u8 = if (f.label) |label|
        if (self.loopLabelUsed(f.body, label))
            try std.fmt.allocPrint(a, "lls_loop_{d}", .{id})
        else
            null
    else
        null;

    self.pushScope();
    const probe = try a.create(Binding);
    probe.* = .{ .name = f.captures[0].name, .zig_name = "", .display = payload.display };
    try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, probe);
    try self.preScanStmt(f.body);
    const cap_read = probe.read;
    self.popScope();

    try self.loop_targets.append(a, .{ .label = f.label, .zig_label = zig_label, .scope_depth = self.scopes.items.len });
    defer _ = self.loop_targets.pop();

    try self.writeIndent();
    if (zig_label) |label| try self.writer.print("{s}: ", .{label});
    try self.writer.writeAll("while (true) {\n");
    self.indent += 1;
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ tmp_name, cond_t.zig, try self.emitExpr(f.expr) });
    try self.writeIndent();
    try self.writer.print("if ({s}) |{s}| {{\n", .{ tmp_name, cap_name });
    self.indent += 1;

    self.pushScope();
    defer self.popScope();
    const b = try a.create(Binding);
    b.* = .{ .name = f.captures[0].name, .zig_name = cap_name, .display = payload.display };
    try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, b);
    if (!cap_read) {
        try self.writeIndent();
        try self.writer.print("_ = {s};\n", .{cap_name});
    }
    const body = try self.forBody(node, f);
    try self.emitStatements(body.statements);
    try self.emitDeferredAtScopeEnd(body.statements);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("} else break;\n");
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
}

pub fn emitCondition(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const t = try self.valueType(node);
    if (t.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' before use as an @if condition", .{});
    }
    if (t.kind != .bool) {
        return self.failAt(node, "@if condition must be boolean, got '{s}'", .{t.display});
    }
    return self.emitExpr(node);
}

pub fn emitContinue(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Continue) !void {
    const target = self.findLoopTarget(c.label) orelse {
        if (c.label) |label| {
            return self.failAt(node, "native backend cannot find loop with label '{s}'", .{label});
        }
        return self.failAt(node, "continue outside a loop", .{});
    };
    try self.emitDeferredFromDepth(target.scope_depth);
    try self.writeIndent();
    if (target.zig_label) |zig_label| {
        try self.writer.print("continue :{s};\n", .{zig_label});
    } else {
        try self.writer.writeAll("continue;\n");
    }
}

pub fn emitEqualityCode(self: *Emitter, left: []const u8, lt: ValType, right_node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const rt = try self.valueType(right_node);
    if (rt.may_error) {
        return self.failAt(right_node, "error-union value must be handled with '?' before @switch", .{});
    }
    if (lt.kind != rt.kind) {
        return self.failAt(right_node, "cannot compare @switch '{s}' with pattern '{s}'", .{ lt.display, rt.display });
    }
    switch (lt.kind) {
        .string => return std.fmt.allocPrint(a, "rt.arith.eqStr({s}, {s})", .{ left, try self.emitExpr(right_node) }),
        .bool => return std.fmt.allocPrint(a, "rt.arith.eqBool({s}, {s})", .{ left, try self.emitExpr(right_node) }),
        .int => return std.fmt.allocPrint(a, "rt.arith.eqI64({s}, {s})", .{
            try self.i64Code(left, lt), try self.emitI64Operand(right_node),
        }),
        .float => return std.fmt.allocPrint(a, "rt.arith.eqF64({s}, {s})", .{
            try self.f64Code(left, lt), try self.emitF64Operand(right_node),
        }),
        else => return self.failAt(right_node, "native backend (Phase 3) does not support @switch on '{s}' yet", .{lt.display}),
    }
}

pub fn emitExprStatement(self: *Emitter, node: *ast_mod.Node) !void {
    const t = try self.valueType(node);
    if (t.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' or returned", .{});
    }
    const code = try self.emitExpr(node);
    try self.writeIndent();
    if (t.kind == .void) {
        try self.writer.print("{s};\n", .{code});
    } else {
        try self.writer.print("_ = {s};\n", .{code});
    }
}

pub fn emitForStmt(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) anyerror!void {
    if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..")) {
        return self.emitRangeFor(node, f);
    }
    const iter_t = try self.valueType(f.expr);
    if (self.state.for_is_cond.contains(f) or f.captures.len == 0 or iter_t.kind == .optional) {
        return self.emitCondFor(node, f);
    }
    return self.emitIterableFor(node, f);
}

pub fn emitIterableFor(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) !void {
    const a = self.arena.allocator();
    const iter_t = try self.valueType(f.expr);
    if (iter_t.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' before iteration", .{});
    }
    if (iter_t.kind != .array and iter_t.kind != .slice and iter_t.kind != .string) {
        return self.failAt(node, "native backend cannot iterate over '{s}' yet", .{iter_t.display});
    }
    const elem_t = iter_t.elem orelse {
        return self.failAt(node, "native backend cannot determine the element type of '{s}'", .{iter_t.display});
    };

    self.counter += 1;
    const id = self.counter;
    const iter_name = try std.fmt.allocPrint(a, "lls_iter_{d}", .{id});
    const zig_label: ?[]const u8 = if (f.label) |label|
        if (self.loopLabelUsed(f.body, label))
            try std.fmt.allocPrint(a, "lls_loop_{d}", .{id})
        else
            null
    else
        null;

    const cap0_name = try self.localName(f.captures[0].name);
    const cap1_name = if (f.captures.len > 1) try self.localName(f.captures[1].name) else "";
    const raw1_name = try std.fmt.allocPrint(a, "lls_iter_i_{d}", .{id});

    self.pushScope();
    const probe0 = try a.create(Binding);
    probe0.* = .{ .name = f.captures[0].name, .zig_name = "", .display = elem_t.display };
    try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, probe0);
    var probe1: ?*Binding = null;
    if (f.captures.len > 1) {
        const b = try a.create(Binding);
        b.* = .{ .name = f.captures[1].name, .zig_name = "", .display = "int" };
        try self.scopes.items[self.scopes.items.len - 1].put(f.captures[1].name, b);
        probe1 = b;
    }
    const body = try self.forBody(node, f);
    try self.preScanStmt(f.body);
    const cap0_read = probe0.read;
    const cap1_read = if (probe1) |b| b.read else false;
    self.popScope();

    try self.writeIndent();
    try self.writer.writeAll("{\n");
    self.indent += 1;
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ iter_name, iter_t.zig, try self.emitExpr(f.expr) });

    try self.loop_targets.append(a, .{ .label = f.label, .zig_label = zig_label, .scope_depth = self.scopes.items.len });
    defer _ = self.loop_targets.pop();

    try self.writeIndent();
    if (zig_label) |label| try self.writer.print("{s}: ", .{label});
    if (f.captures.len > 1) {
        try self.writer.print("for ({s}, 0..) |{s}, {s}| {{\n", .{ iter_name, cap0_name, raw1_name });
    } else {
        try self.writer.print("for ({s}) |{s}| {{\n", .{ iter_name, cap0_name });
    }
    self.indent += 1;

    self.pushScope();
    defer self.popScope();
    {
        const b = try a.create(Binding);
        b.* = .{ .name = f.captures[0].name, .zig_name = cap0_name, .display = elem_t.display };
        try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, b);
    }
    if (f.captures.len > 1) {
        try self.writeIndent();
        try self.writer.print("const {s}: i64 = @intCast({s});\n", .{ cap1_name, raw1_name });
        const b = try a.create(Binding);
        b.* = .{ .name = f.captures[1].name, .zig_name = cap1_name, .display = "int" };
        try self.scopes.items[self.scopes.items.len - 1].put(f.captures[1].name, b);
    }
    if (!cap0_read) {
        try self.writeIndent();
        try self.writer.print("_ = {s};\n", .{cap0_name});
    }
    if (f.captures.len > 1 and !cap1_read) {
        try self.writeIndent();
        try self.writer.print("_ = {s};\n", .{cap1_name});
    }

    try self.emitStatements(body.statements);
    try self.emitDeferredAtScopeEnd(body.statements);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
}

pub fn emitIfBody(self: *Emitter, body: *ast_mod.Node) !void {
    const block = switch (body.*) {
        .block => |b| b,
        else => return self.failAt(body, "native backend expects an @if block body", .{}),
    };
    self.pushScope();
    try self.emitStatements(block.statements);
    try self.emitDeferredAtScopeEnd(block.statements);
    self.popScope();
}

pub fn emitIfChain(self: *Emitter, i: *const ast_mod.If, first: bool) anyerror!void {
    if (i.pipe_value != null) return self.emitCaptureIfChain(i, first);

    const cond = try self.emitCondition(i.condition);
    if (first) try self.writeIndent();
    try self.writer.print("if ({s}) {{\n", .{cond});
    self.indent += 1;
    try self.emitIfBody(i.body);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    try self.emitIfElse(i.else_body);
}

pub fn emitCaptureIfChain(self: *Emitter, i: *const ast_mod.If, first: bool) anyerror!void {
    const a = self.arena.allocator();
    const cond_t = try self.valueType(i.condition);
    if (cond_t.may_error) {
        return self.failAt(i.condition, "native backend does not support error-union @if captures yet", .{});
    }
    if (cond_t.kind != .optional) {
        return self.failAt(i.condition, "@if capture requires an optional value, got '{s}'", .{cond_t.display});
    }
    const payload = cond_t.payload orelse {
        return self.failAt(i.condition, "native backend cannot determine the optional payload type", .{});
    };
    const pipe = i.pipe_value.?;
    const capture_name = switch (pipe.*) {
        .primary => |p| if (p.kind == .identifier or p.kind == .register)
            p.name
        else
            return self.failAt(pipe, "native backend expects an identifier capture", .{}),
        else => return self.failAt(pipe, "native backend expects an identifier capture", .{}),
    };

    self.counter += 1;
    const id = self.counter;
    const tmp_name = try std.fmt.allocPrint(a, "lls_ifopt_{d}", .{id});
    const cap_name = try self.localName(capture_name);

    self.pushScope();
    const probe = try a.create(Binding);
    probe.* = .{ .name = capture_name, .zig_name = "", .display = payload.display };
    try self.scopes.items[self.scopes.items.len - 1].put(capture_name, probe);
    try self.preScanStmt(i.body);
    const cap_read = probe.read;
    self.popScope();

    if (first) try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ tmp_name, cond_t.zig, try self.emitExpr(i.condition) });
    if (first) try self.writeIndent();
    try self.writer.print("if ({s}) |{s}| {{\n", .{ tmp_name, cap_name });
    self.indent += 1;
    self.pushScope();
    defer self.popScope();
    const b = try a.create(Binding);
    b.* = .{ .name = capture_name, .zig_name = cap_name, .display = payload.display };
    try self.scopes.items[self.scopes.items.len - 1].put(capture_name, b);
    if (!cap_read) {
        try self.writeIndent();
        try self.writer.print("_ = {s};\n", .{cap_name});
    }
    const body = switch (i.body.*) {
        .block => |*blk| blk,
        else => return self.failAt(i.body, "native backend expects an @if block body", .{}),
    };
    try self.emitStatements(body.statements);
    try self.emitDeferredAtScopeEnd(body.statements);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    try self.emitIfElse(i.else_body);
}

pub fn emitIfElse(self: *Emitter, else_body: ?*ast_mod.Node) !void {
    if (else_body) |eb| {
        switch (eb.*) {
            .if_expr => |*nested| {
                if (nested.pipe_value != null) {
                    try self.writer.writeAll(" else {\n");
                    self.indent += 1;
                    try self.emitCaptureIfChain(nested, true);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.writer.writeAll("}\n");
                } else {
                    try self.writer.writeAll(" else ");
                    try self.emitIfChain(nested, false);
                }
            },
            .block => {
                try self.writer.writeAll(" else {\n");
                self.indent += 1;
                try self.emitIfBody(eb);
                self.indent -= 1;
                try self.writeIndent();
                try self.writer.writeAll("}\n");
            },
            else => return self.failAt(eb, "native backend expects an @else block or @if", .{}),
        }
    } else {
        try self.writer.writeAll("\n");
    }
}

pub fn emitIfStmt(self: *Emitter, node: *ast_mod.Node, i: *const ast_mod.If) !void {
    _ = node;
    try self.emitIfChain(i, true);
}

pub fn emitIfValue(self: *Emitter, node: *ast_mod.Node, i: *const ast_mod.If) ![]const u8 {
    if (i.pipe_value != null) {
        return self.failAt(node, "native backend does not support @if captures yet", .{});
    }
    if (i.else_body == null) {
        return self.failAt(node, "value-producing @if requires @else", .{});
    }
    const a = self.arena.allocator();
    const vt = try self.valueType(node);
    try self.requireValueType(node, vt);

    self.counter += 1;
    const zig_label = try std.fmt.allocPrint(a, "lls_if_{d}", .{self.counter});
    try self.break_targets.append(a, .{
        .label = i.label,
        .zig_label = zig_label,
        .value_type = vt,
        .scope_depth = self.scopes.items.len,
    });
    defer _ = self.break_targets.pop();

    var buf: std.ArrayList(u8) = .empty;
    const old_writer = self.writer;
    self.writer = buf.writer(a).any();
    defer self.writer = old_writer;

    self.indent += 1;
    try self.emitIfChain(i, true);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    return std.fmt.allocPrint(a, "{s}: {{\n{s}", .{ zig_label, buf.items });
}

pub fn emitDefer(self: *Emitter, node: *ast_mod.Node, d: *const ast_mod.Defer) !void {
    if (d.is_errdefer) {
        return self.failAt(node, "native backend (Phase 4) does not support @errdefer yet", .{});
    }
    if (self.defer_scopes.items.len == 0) {
        return self.failAt(node, "@defer outside a function", .{});
    }
    try self.defer_scopes.items[self.defer_scopes.items.len - 1].append(self.arena.allocator(), d.body);
}

pub fn emitLineMarker(self: *Emitter, node: *ast_mod.Node) !void {
    if (self.options.release) return;
    const loc = node.loc();
    if (loc.line == 0) return;
    try self.writeIndent();
    try self.writer.print("ctx.setLine({d}, {d});\n", .{ loc.line, loc.column });
}

pub fn emitLocalDeclaration(self: *Emitter, node: *ast_mod.Node, d: *const ast_mod.Declaration) !void {
    const info = self.infos.get(node) orelse {
        return self.failAt(node, "internal: missing binding for local '{s}'", .{d.name});
    };
    const vt = try self.classify(node, info.display);
    try self.requireValueType(node, vt);
    if (info.zig_name.len == 0) info.zig_name = try self.localName(d.name);

    const init_code = if (d.type_annotation != null)
        try self.emitValueCoerced(d.value, vt)
    else
        try self.emitExpr(d.value);

    const needs_var = info.reassigned or (info.assigned and vt.kind != .pointer and vt.kind != .slice);
    const kw = if (needs_var) "var" else "const";
    try self.writeIndent();
    try self.writer.print("{s} {s}: {s} = {s};\n", .{ kw, info.zig_name, vt.zig, init_code });

    try self.scopes.items[self.scopes.items.len - 1].put(d.name, info);
    if (!info.read) {
        try self.writeIndent();
        if (info.assigned) {
            try self.writer.print("_ = &{s};\n", .{info.zig_name});
        } else {
            try self.writer.print("_ = {s};\n", .{info.zig_name});
        }
    }
}

pub fn emitProngBody(self: *Emitter, body: *ast_mod.Node) !void {
    const block = switch (body.*) {
        .block => |b| b,
        else => return self.failAt(body, "native backend expects a @switch prong block", .{}),
    };
    self.pushScope();
    try self.emitStatements(block.statements);
    try self.emitDeferredAtScopeEnd(block.statements);
    self.popScope();
}

pub fn emitRangeFor(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) !void {
    if (f.expr.* != .binary or !std.mem.eql(u8, f.expr.binary.operator, "..")) {
        return self.failAt(node, "range @for requires start..end", .{});
    }
    const a = self.arena.allocator();
    self.counter += 1;
    const id = self.counter;
    const start_name = try std.fmt.allocPrint(a, "lls_loop_start_{d}", .{id});
    const end_name = try std.fmt.allocPrint(a, "lls_loop_end_{d}", .{id});
    const zig_label: ?[]const u8 = if (f.label) |label|
        if (self.loopLabelUsed(f.body, label))
            try std.fmt.allocPrint(a, "lls_loop_{d}", .{id})
        else
            null
    else
        null;

    const cap_name: []const u8 = if (f.captures.len > 0)
        try self.localName(f.captures[0].name)
    else
        try std.fmt.allocPrint(a, "lls_loop_i_{d}", .{id});

    const start = try self.emitI64Operand(f.expr.binary.left);
    const end = try self.emitI64Operand(f.expr.binary.right);

    try self.writeIndent();
    try self.writer.writeAll("{\n");
    self.indent += 1;
    try self.writeIndent();
    try self.writer.print("const {s}: i64 = {s};\n", .{ start_name, start });
    try self.writeIndent();
    try self.writer.print("const {s}: i64 = {s};\n", .{ end_name, end });
    try self.writeIndent();
    try self.writer.print("var {s}: i64 = {s};\n", .{ cap_name, start_name });

    self.pushScope();
    defer self.popScope();
    if (f.captures.len > 0) {
        const b = try a.create(Binding);
        b.* = .{ .name = f.captures[0].name, .zig_name = cap_name, .display = "int" };
        try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, b);
    }

    try self.loop_targets.append(a, .{ .label = f.label, .zig_label = zig_label, .scope_depth = self.scopes.items.len - 1 });
    defer _ = self.loop_targets.pop();

    try self.writeIndent();
    if (zig_label) |label| try self.writer.print("{s}: ", .{label});
    try self.writer.print("while ({s} < {s}) : ({s} +%= 1) {{\n", .{
        cap_name, end_name, cap_name,
    });
    self.indent += 1;
    const body = try self.forBody(node, f);
    try self.emitStatements(body.statements);
    try self.emitDeferredAtScopeEnd(body.statements);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
}

pub fn emitStatements(self: *Emitter, statements: []*ast_mod.Node) !void {
    for (statements) |s| {
        try self.emitStmt(s);
        if (self.stmtTerminates(s)) break;
    }
}

pub fn emitStmt(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    try self.emitLineMarker(node);
    switch (node.*) {
        .declaration => |*d| {
            if (root_mod.isImportDecl(d)) return;
            try self.emitLocalDeclaration(node, d);
        },
        .return_expr => |r| {
            if (r.return_value) |v| {
                if (self.cur_ret.kind == .void) {
                    return self.failAt(v, "cannot return a value from a void function", .{});
                }
                const code = try self.emitValueCoerced(v, self.cur_ret);
                self.counter += 1;
                const tmp = try std.fmt.allocPrint(self.arena.allocator(), "lls_ret_{d}", .{self.counter});
                try self.writeIndent();
                try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, self.cur_ret.zig, code });
                try self.emitDeferredFromDepth(0);
                try self.writeIndent();
                try self.writer.print("return {s};\n", .{tmp});
            } else {
                if (self.cur_ret.kind != .void) {
                    return self.failAt(node, "missing return value for type '{s}'", .{self.cur_ret.display});
                }
                try self.emitDeferredFromDepth(0);
                try self.writeIndent();
                try self.writer.writeAll("return;\n");
            }
        },
        .block => |b| {
            try self.writeIndent();
            try self.writer.writeAll("{\n");
            self.indent += 1;
            self.pushScope();
            try self.emitStatements(b.statements);
            try self.emitDeferredAtScopeEnd(b.statements);
            self.popScope();
            self.indent -= 1;
            try self.writeIndent();
            try self.writer.writeAll("}\n");
        },
        .assignment => |*asn| try self.emitAssignment(node, asn),
        .if_expr => |i| try self.emitIfStmt(node, &i),
        .switch_expr => |sw| try self.emitSwitchStmt(node, &sw),
        .for_expr => |f| try self.emitForStmt(node, &f),
        .break_expr => |b| try self.emitBreak(node, &b),
        .continue_expr => |c| try self.emitContinue(node, &c),
        .defer_stmt => |d| try self.emitDefer(node, &d),
        .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
        else => try self.emitExprStatement(node),
    }
}

pub fn emitSwitchChain(self: *Emitter, sw: *const ast_mod.Switch, scrut: []const u8, scrut_t: ValType, first: bool) !void {
    var wrote_any = false;
    var else_prong: ?ast_mod.SwitchProng = null;
    for (sw.prongs) |prong| {
        if (prong.is_else) {
            else_prong = prong;
            continue;
        }
        const cond = try self.emitSwitchCondition(prong.patterns, scrut, scrut_t);
        if (!wrote_any) {
            if (first) try self.writeIndent();
            try self.writer.print("if ({s}) {{\n", .{cond});
        } else {
            try self.writer.print(" else if ({s}) {{\n", .{cond});
        }
        self.indent += 1;
        try self.emitProngBody(prong.body);
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}");
        wrote_any = true;
    }

    if (else_prong) |prong| {
        if (wrote_any) {
            try self.writer.writeAll(" else {\n");
        } else {
            if (first) try self.writeIndent();
            try self.writer.writeAll("{\n");
        }
        self.indent += 1;
        try self.emitProngBody(prong.body);
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}\n");
        return;
    }
    if (wrote_any) try self.writer.writeAll("\n");
}

pub fn emitSwitchCondition(self: *Emitter, patterns: []*ast_mod.Node, scrut: []const u8, scrut_t: ValType) ![]const u8 {
    const a = self.arena.allocator();
    if (patterns.len == 0) {
        return self.failNoLoc("native backend expects at least one @switch pattern", .{});
    }
    var conds: std.ArrayList([]const u8) = .empty;
    for (patterns) |pat| {
        try conds.append(a, try self.emitEqualityCode(scrut, scrut_t, pat));
    }
    return std.mem.join(a, " or ", conds.items);
}

pub fn emitSwitchStmt(self: *Emitter, node: *ast_mod.Node, sw: *const ast_mod.Switch) !void {
    const vt = try self.switchScrutineeType(node, sw);
    const a = self.arena.allocator();
    self.counter += 1;
    const scrut_name = try std.fmt.allocPrint(a, "lls_scrut_{d}", .{self.counter});
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{
        scrut_name, vt.zig, try self.emitExpr(sw.condition),
    });
    try self.emitSwitchChain(sw, scrut_name, vt, true);
}

pub fn emitSwitchValue(self: *Emitter, node: *ast_mod.Node, sw: *const ast_mod.Switch) ![]const u8 {
    var has_else = false;
    for (sw.prongs) |prong| {
        if (prong.is_else) has_else = true;
    }
    if (!has_else) {
        return self.failAt(node, "value-producing @switch requires @else", .{});
    }
    const a = self.arena.allocator();
    const vt = try self.switchScrutineeType(node, sw);
    const result_t = try self.valueType(node);
    try self.requireValueType(node, result_t);

    self.counter += 1;
    const id = self.counter;
    const zig_label = try std.fmt.allocPrint(a, "lls_sw_{d}", .{id});
    const scrut_name = try std.fmt.allocPrint(a, "lls_scrut_{d}", .{id});
    try self.break_targets.append(a, .{
        .label = sw.label,
        .zig_label = zig_label,
        .value_type = result_t,
        .scope_depth = self.scopes.items.len,
    });
    defer _ = self.break_targets.pop();

    var buf: std.ArrayList(u8) = .empty;
    const old_writer = self.writer;
    self.writer = buf.writer(a).any();
    defer self.writer = old_writer;

    self.indent += 1;
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{
        scrut_name, vt.zig, try self.emitExpr(sw.condition),
    });
    try self.emitSwitchChain(sw, scrut_name, vt, true);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    return std.fmt.allocPrint(a, "{s}: {{\n{s}", .{ zig_label, buf.items });
}

pub fn findBreakTarget(self: *Emitter, label: ?[]const u8) ?*const BreakTarget {
    var i = self.break_targets.items.len;
    while (i > 0) {
        i -= 1;
        const target = &self.break_targets.items[i];
        if (label) |want| {
            const have = target.label orelse continue;
            if (std.mem.eql(u8, have, want)) return target;
        } else {
            return target;
        }
    }
    return null;
}

pub fn findLoopTarget(self: *Emitter, label: ?[]const u8) ?*const LoopTarget {
    var i = self.loop_targets.items.len;
    while (i > 0) {
        i -= 1;
        const target = &self.loop_targets.items[i];
        if (label) |want| {
            const have = target.label orelse continue;
            if (std.mem.eql(u8, have, want)) return target;
        } else {
            return target;
        }
    }
    return null;
}

pub fn forBody(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) !*const ast_mod.Block {
    return switch (f.body.*) {
        .block => |*b| b,
        else => self.failAt(node, "@for body must be a block", .{}),
    };
}

pub fn loopLabelUsed(self: *Emitter, node: *ast_mod.Node, label: []const u8) bool {
    switch (node.*) {
        .break_expr => |b| {
            if (b.label) |l| return std.mem.eql(u8, l, label);
        },
        .continue_expr => |c| {
            if (c.label) |l| return std.mem.eql(u8, l, label);
        },
        .block => |b| {
            for (b.statements) |s| {
                if (self.loopLabelUsed(s, label)) return true;
            }
        },
        .declaration => |d| return self.loopLabelUsed(d.value, label),
        .return_expr => |r| {
            if (r.return_value) |v| return self.loopLabelUsed(v, label);
        },
        .defer_stmt => |d| return self.loopLabelUsed(d.body, label),
        .assignment => |asn| return self.loopLabelUsed(asn.right, label),
        .if_expr => |i| {
            if (self.loopLabelUsed(i.condition, label)) return true;
            if (i.pipe_value) |v| {
                if (self.loopLabelUsed(v, label)) return true;
            }
            if (self.loopLabelUsed(i.body, label)) return true;
            if (i.else_body) |e| return self.loopLabelUsed(e, label);
        },
        .switch_expr => |sw| {
            if (self.loopLabelUsed(sw.condition, label)) return true;
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| {
                    if (self.loopLabelUsed(pat, label)) return true;
                }
                if (self.loopLabelUsed(prong.body, label)) return true;
            }
        },
        .for_expr => |f| {
            if (self.loopLabelUsed(f.expr, label)) return true;
            if (self.loopLabelUsed(f.body, label)) return true;
        },
        .binary => |b| {
            if (self.loopLabelUsed(b.left, label)) return true;
            return self.loopLabelUsed(b.right, label);
        },
        .unary => |u| return self.loopLabelUsed(u.arg, label),
        .call => |c| {
            if (self.loopLabelUsed(c.callee, label)) return true;
            for (c.args) |arg| {
                if (self.loopLabelUsed(arg, label)) return true;
            }
        },
        .member => |m| {
            if (self.loopLabelUsed(m.object, label)) return true;
            return self.loopLabelUsed(m.property, label);
        },
        .index => |ix| {
            if (self.loopLabelUsed(ix.object, label)) return true;
            if (ix.index) |v| {
                if (self.loopLabelUsed(v, label)) return true;
            }
            if (ix.end) |v| {
                if (self.loopLabelUsed(v, label)) return true;
            }
            if (ix.type_annotation) |v| return self.loopLabelUsed(v, label);
        },
        .array_literal => |al| {
            for (al.elements) |e| {
                if (self.loopLabelUsed(e, label)) return true;
            }
        },
        .try_expr => |t| return self.loopLabelUsed(t.expression, label),
        .unwrap_expr => |u| return self.loopLabelUsed(u.expression, label),
        .error_expr => |e| {
            for (e.args) |arg| {
                if (self.loopLabelUsed(arg, label)) return true;
            }
        },
        .struct_init => |si| {
            if (self.loopLabelUsed(si.type_expr, label)) return true;
            for (si.fields) |field| {
                if (self.loopLabelUsed(field.value, label)) return true;
            }
        },
        .comptime_expr => |ce| return self.loopLabelUsed(ce.expr, label),
        else => {},
    }
    return false;
}

pub fn switchScrutineeType(self: *Emitter, node: *ast_mod.Node, sw: *const ast_mod.Switch) !ValType {
    const vt = try self.valueType(sw.condition);
    if (vt.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' before @switch", .{});
    }
    switch (vt.kind) {
        .int, .float, .bool, .string => {},
        else => return self.failAt(node, "native backend (Phase 3) does not support @switch on '{s}' yet", .{vt.display}),
    }
    return vt;
}
