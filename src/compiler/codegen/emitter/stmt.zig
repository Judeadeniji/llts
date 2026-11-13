const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const ir = @import("../../typecheck/ir.zig");
const state_mod = @import("../../state.zig");
const root_mod = @import("root.zig");
const expr_mod = @import("expr.zig");
const Emitter = root_mod.Emitter;
const ValType = root_mod.ValType;
const Binding = root_mod.Binding;
const BreakTarget = root_mod.BreakTarget;
const LoopTarget = root_mod.LoopTarget;
const SwitchContinueTarget = root_mod.SwitchContinueTarget;

pub fn emitAssignment(self: *Emitter, node: *ast_mod.Node, asn: *const ast_mod.Assignment) !void {
    const compound = expr_mod.compoundOp(asn.operator);
    if (!std.mem.eql(u8, asn.operator, "=") and compound == null) {
        return self.failAt(node, "native backend does not support compound assignment '{s}'", .{asn.operator});
    }
    if (asn.left.* == .primary and
        (asn.left.primary.kind == .identifier or asn.left.primary.kind == .register) and
        std.mem.eql(u8, asn.left.primary.name, "_"))
    {
        if (compound != null) {
            return self.failAt(node, "cannot use compound assignment with discard '_'", .{});
        }
        // `_ = expr;` evaluates for effect. Function values and module names
        // have no native representation and exist only to silence unused
        // analysis, so a bare name discards to nothing.
        if (asn.right.* == .primary) {
            const n = asn.right.primary;
            if (n.kind == .identifier or n.kind == .register) {
                if (self.state.functions.contains(n.name)) return;
                if (self.state.fn_aliases.contains(n.name)) return;
                if (self.lookupBindingOptional(n.name)) |b| {
                    if (b.fn_key != null or b.module_path != null) return;
                }
                if (self.globals.get(n.name)) |g| {
                    if (g.fn_key != null or g.module_path != null) return;
                }
            }
        }
        const code = try expr_mod.emitExpr(self, asn.right);
        try self.writeIndent();
        try self.writer.print("_ = {s};\n", .{code});
        return;
    }
    switch (asn.left.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) {
                return self.failAt(asn.left, "native backend only supports assigning to names", .{});
            }
            const target = try self.lookupBinding(asn.left, p.name);
            const vt = try self.valTypeFor(node, target.ir_type, target.display);
            try self.requireValueType(node, vt);
            const rhs = if (compound) |c|
                try expr_mod.emitCompoundValue(self, node, asn.left, asn.right, c, vt)
            else
                try expr_mod.emitValueCoerced(self, asn.right, vt);
            try self.writeIndent();
            try self.writer.print("{s} = {s};\n", .{ target.zig_name, rhs });
        },
        .member => |*m| {
            const target = (try expr_mod.resolveMemberField(self, asn.left, m)) orelse {
                return self.failAt(asn.left, "native backend only supports assigning to struct fields", .{});
            };
            const field = target.info.fields[target.index];
            try self.requireValueType(asn.left, field.vt);
            const rhs = if (compound) |c|
                try expr_mod.emitCompoundValue(self, node, asn.left, asn.right, c, field.vt)
            else
                try expr_mod.emitValueCoerced(self, asn.right, field.vt);
            const lvalue = try emitPlaceLvalue(self, asn.left);
            try self.writeIndent();
            try self.writer.print("{s} = {s};\n", .{ lvalue, rhs });
        },
        .index => |*ix| try emitIndexAssignment(self, node, asn, ix, compound),
        else => return self.failAt(asn.left, "native backend only supports assigning to names, fields, or array elements", .{}),
    }
}

pub fn emitIndexAssignment(
    self: *Emitter,
    node: *ast_mod.Node,
    asn: *const ast_mod.Assignment,
    ix: *const ast_mod.Index,
    compound: ?expr_mod.CompoundOp,
) !void {
    if (ix.is_slice) {
        return self.failAt(node, "Cannot assign to a slice view", .{});
    }
    // Reject `"hi"[0] = …` before place lowering (literals are not lvalues).
    if (isStringLiteralExpr(ix.object)) {
        return self.failAt(node, "cannot mutate a string literal", .{});
    }
    const a = self.arena.allocator();
    var obj_t = try self.valueType(ix.object);
    var obj_code = try emitPlaceLvalue(self, ix.object);
    const was_pointer = obj_t.kind == .pointer;
    if (was_pointer) {
        const payload = obj_t.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{obj_t.display});
        obj_t = payload.*;
        obj_code = try std.fmt.allocPrint(a, "({s}).*", .{obj_code});
    }
    if (obj_t.is_const or obj_t.kind == .string) {
        return self.failAt(node, "cannot assign to elements of a const slice or string", .{});
    }
    if (obj_t.kind == .struct_) {
        if (try self.structInfoForValType(node, obj_t)) |info| {
            if (ix.index) |idx_node| {
                const idx_str = switch (idx_node.*) {
                    .literal => |lit| if (lit.literal_type == .number) lit.value else null,
                    else => null,
                };
                if (idx_str) |s| {
                    if (info.field_index.get(s)) |fidx| {
                        const field = info.fields[fidx];
                        const rhs = if (compound) |c|
                            try expr_mod.emitCompoundValue(self, node, asn.left, asn.right, c, field.vt)
                        else
                            try expr_mod.emitValueCoerced(self, asn.right, field.vt);
                        try self.writeIndent();
                        try self.writer.print("{s}.{s} = {s};\n", .{ obj_code, field.zig_name, rhs });
                        return;
                    }
                }
            }
        }
    }
    const word: []const u8 = switch (obj_t.kind) {
        .array => "Array",
        .slice => "Slice",
        else => return self.failAt(node, "native backend cannot assign into '{s}' yet", .{obj_t.display}),
    };
    const use: []const u8 = switch (obj_t.kind) {
        .slice => "slice",
        else => "arr",
    };
    const index_node = ix.index orelse return self.failAt(node, "expected index expression", .{});
    const elem_t = obj_t.elem orelse {
        return self.failAt(node, "native backend cannot determine the element type of '{s}'", .{obj_t.display});
    };
    const rhs = if (compound) |c|
        try expr_mod.emitCompoundValue(self, node, asn.left, asn.right, c, elem_t.*)
    else
        try expr_mod.emitValueCoerced(self, asn.right, elem_t.*);
    const index_code = try expr_mod.emitI64Operand(self, index_node);

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
            const target = (try expr_mod.resolveMemberField(self, node, &m)) orelse {
                return self.failAt(node, "native backend only supports assigning to struct fields", .{});
            };
            const field = target.info.fields[target.index];
            const base = try emitPlaceLvalue(self, m.object);
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
            const index_code = try expr_mod.emitI64Operand(self, index_node);
            const obj_t_full = try self.valueType(ix.object);
            var base = try emitPlaceLvalue(self, ix.object);
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
    return expr_mod.emitExpr(self, node);
}

pub fn emitBreak(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Break) !void {
    if (b.value) |value| {
        const target = findBreakTarget(self, b.label) orelse {
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
        const code = try expr_mod.emitStrongCoercion(self, value, target_type);
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
        if (findBreakTarget(self, label) != null) {
            return self.failAt(node, "break to a value expression requires a value", .{});
        }
    }
    const target = findLoopTarget(self, b.label) orelse {
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
    if (f.captures.len > 0) return emitCaptureCondFor(self, node, f);
    const a = self.arena.allocator();
    const condition = try emitBoolCondition(self, f.expr, "@for");
    self.counter += 1;
    const zig_label = try loopZigLabel(self, f, self.counter);
    try self.loop_targets.append(a, .{ .label = f.label, .zig_label = zig_label, .scope_depth = self.scopes.items.len });
    defer _ = self.loop_targets.pop();

    try self.writeIndent();
    if (zig_label) |label| try self.writer.print("{s}: ", .{label});
    try self.writer.print("while ({s}) {{\n", .{condition});
    self.indent += 1;
    self.pushScope();
    defer self.popScope();
    const body = try forBody(self, node, f);
    try emitStatements(self, body.statements);
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
    const payload_ir: ?ir.Type = if (self.recordedType(f.expr)) |t| ir.optionalPayload(t) else null;

    self.counter += 1;
    const id = self.counter;
    const tmp_name = try std.fmt.allocPrint(a, "lls_foropt_{d}", .{id});
    const cap_name = try self.localName(f.captures[0].name);
    const zig_label = try loopZigLabel(self, f, id);

    const cap_read = if (self.state.for_capture_facts.get(node)) |facts| facts[0].read else false;

    try self.loop_targets.append(a, .{ .label = f.label, .zig_label = zig_label, .scope_depth = self.scopes.items.len });
    defer _ = self.loop_targets.pop();

    try self.writeIndent();
    if (zig_label) |label| try self.writer.print("{s}: ", .{label});
    try self.writer.writeAll("while (true) {\n");
    self.indent += 1;
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ tmp_name, cond_t.zig, try expr_mod.emitExpr(self, f.expr) });
    try self.writeIndent();
    try self.writer.print("if ({s}) |{s}| {{\n", .{ tmp_name, cap_name });
    self.indent += 1;

    self.pushScope();
    defer self.popScope();
    const b = try a.create(Binding);
    b.* = .{ .name = f.captures[0].name, .zig_name = cap_name, .display = payload.display, .ir_type = payload_ir };
    try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, b);
    if (!cap_read) {
        try self.writeIndent();
        try self.writer.print("_ = {s};\n", .{cap_name});
    }
    const body = try forBody(self, node, f);
    try emitStatements(self, body.statements);
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
    return expr_mod.emitExpr(self, node);
}

pub fn emitContinue(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Continue) !void {
    if (c.value) |value| {
        const label = c.label orelse {
            return self.failAt(node, "'continue' with a value requires a label naming an enclosing @switch", .{});
        };
        const target = findSwitchContinueTarget(self, label) orelse {
            return self.failAt(node, "native backend cannot find @switch with label '{s}'", .{label});
        };
        const a = self.arena.allocator();
        const code = try expr_mod.emitStrongCoercion(self, value, target.scrut_type);
        self.counter += 1;
        const tmp = try std.fmt.allocPrint(a, "lls_cont_{d}", .{self.counter});
        try self.writeIndent();
        try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, target.scrut_type.zig, code });
        try self.emitDeferredFromDepth(target.scope_depth);
        try self.writeIndent();
        try self.writer.print("{s} = {s};\n", .{ target.scrut_name, tmp });
        try self.writeIndent();
        try self.writer.print("continue :{s};\n", .{target.zig_label});
        return;
    }
    const target = findLoopTarget(self, c.label) orelse {
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

fn findSwitchContinueTarget(self: *Emitter, label: []const u8) ?*const SwitchContinueTarget {
    var i = self.switch_targets.items.len;
    while (i > 0) {
        i -= 1;
        const target = &self.switch_targets.items[i];
        if (std.mem.eql(u8, target.label, label)) return target;
    }
    return null;
}

pub fn emitEqualityCode(self: *Emitter, left: []const u8, lt: ValType, right_node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const rt = try self.valueType(right_node);
    if (rt.may_error and !(lt.kind == .error_value and rt.kind == .error_value)) {
        return self.failAt(right_node, "error-union value must be handled with '?' before @switch", .{});
    }
    if (lt.isByteSequence() and rt.isByteSequence()) {
        const left_slice = if (lt.kind == .array) try std.fmt.allocPrint(a, "{s}[0..]", .{left}) else left;
        const r_expr = try expr_mod.emitExpr(self, right_node);
        const right_slice = if (rt.kind == .array) try std.fmt.allocPrint(a, "({s})[0..]", .{r_expr}) else r_expr;
        return std.fmt.allocPrint(a, "rt.arith.eqStr({s}, {s})", .{ left_slice, right_slice });
    }
    if (lt.kind != rt.kind) {
        return self.failAt(right_node, "cannot compare @switch '{s}' with pattern '{s}'", .{ lt.display, rt.display });
    }
    switch (lt.kind) {
        .error_value => return std.fmt.allocPrint(a, "rt.err.eq({s}, {s})", .{ left, try expr_mod.emitExpr(self, right_node) }),
        .string => return std.fmt.allocPrint(a, "rt.arith.eqStr({s}, {s})", .{ left, try expr_mod.emitExpr(self, right_node) }),
        .bool => return std.fmt.allocPrint(a, "rt.arith.eqBool({s}, {s})", .{ left, try expr_mod.emitExpr(self, right_node) }),
        .int => return std.fmt.allocPrint(a, "rt.arith.eqI64({s}, {s})", .{
            try expr_mod.i64Code(self, left, lt), try expr_mod.emitI64Operand(self, right_node),
        }),
        .float => return std.fmt.allocPrint(a, "rt.arith.eqF64({s}, {s})", .{
            try expr_mod.f64Code(self, left, lt), try expr_mod.emitF64Operand(self, right_node),
        }),
        else => return self.failAt(right_node, "native backend does not support @switch on '{s}' yet", .{lt.display}),
    }
}

pub fn emitReturnValue(self: *Emitter, node: *ast_mod.Node, value: *ast_mod.Node) !void {
    _ = node;
    const a = self.arena.allocator();
    const src = try self.valueType(value);
    self.counter += 1;
    const id = self.counter;
    const tmp = try std.fmt.allocPrint(a, "lls_ret_{d}", .{id});
    const val_name = try std.fmt.allocPrint(a, "lls_ret_val_{d}", .{id});
    const err_name = try std.fmt.allocPrint(a, "lls_ret_err_{d}", .{id});

    if (self.cur_ret.kind == .error_value) {
        if (src.kind != .error_value) {
            return self.failAt(value, "cannot return '{s}' from a function returning '{s}'", .{ src.display, self.cur_ret.display });
        }
        try self.writeIndent();
        try self.writer.print("const {s}: rt.err.Error = {s};\n", .{ tmp, try expr_mod.emitExpr(self, value) });
        try self.emitErrorCleanup();
        try self.writeIndent();
        try self.writer.print("return {s};\n", .{tmp});
        return;
    }

    if (self.cur_ret.may_error) {
        if (src.kind == .error_value) {
            try self.writeIndent();
            try self.writer.print("const {s}: rt.err.Error = {s};\n", .{ err_name, try expr_mod.emitExpr(self, value) });
            try self.emitErrorCleanup();
            try self.writeIndent();
            try self.writer.print("return .{{ .err = {s} }};\n", .{err_name});
            return;
        }
        if (src.may_error) {
            if (!std.mem.eql(u8, src.zig, self.cur_ret.zig)) {
                return self.failAt(value, "cannot return error union '{s}' from a function returning '{s}'", .{ src.display, self.cur_ret.display });
            }
            try self.writeIndent();
            try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, src.zig, try expr_mod.emitExpr(self, value) });
            try self.writeIndent();
            try self.writer.print("const lls_ret_result_{d}: {s} = switch ({s}) {{\n", .{ id, self.cur_ret.zig, tmp });
            self.indent += 1;
            try self.writeIndent();
            try self.writer.print(".ok => |{s}| blk: {{\n", .{val_name});
            self.indent += 1;
            try self.emitDeferredFromDepth(0);
            try self.writeIndent();
            try self.writer.print("break :blk .{{ .ok = {s} }};\n", .{val_name});
            self.indent -= 1;
            try self.writeIndent();
            try self.writer.print("}},\n.err => |{s}| blk: {{\n", .{err_name});
            self.indent += 1;
            try self.emitErrorCleanup();
            try self.writeIndent();
            try self.writer.print("break :blk .{{ .err = {s} }};\n", .{err_name});
            self.indent -= 1;
            try self.writeIndent();
            try self.writer.writeAll("},\n");
            self.indent -= 1;
            try self.writeIndent();
            try self.writer.writeAll("};\n");
            try self.writeIndent();
            try self.writer.print("return lls_ret_result_{d};\n", .{id});
            return;
        }
        const success = self.cur_ret.success orelse {
            return self.failAt(value, "native backend cannot determine the success type of '{s}'", .{self.cur_ret.display});
        };
        if (success.kind == .void) {
            try self.emitDeferredFromDepth(0);
            try self.writeIndent();
            try self.writer.writeAll("return .{ .ok = {} };\n");
            return;
        }
        const code = try expr_mod.emitValueCoerced(self, value, success.*);
        try self.writeIndent();
        try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, success.zig, code });
        try self.emitDeferredFromDepth(0);
        try self.writeIndent();
        try self.writer.print("return .{{ .ok = {s} }};\n", .{tmp});
        return;
    }

    const code = try expr_mod.emitValueCoerced(self, value, self.cur_ret);
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, self.cur_ret.zig, code });
    try self.emitDeferredFromDepth(0);
    try self.writeIndent();
    try self.writer.print("return {s};\n", .{tmp});
}

pub fn emitExprStatement(self: *Emitter, node: *ast_mod.Node) !void {
    const t = try self.valueType(node);
    const code = try expr_mod.emitExpr(self, node);
    try self.writeIndent();
    if (t.kind == .void) {
        try self.writer.print("{s};\n", .{code});
    } else {
        try self.writer.print("_ = {s};\n", .{code});
    }
}

pub fn emitForStmt(self: *Emitter, node: *ast_mod.Node, f: *const ast_mod.For) anyerror!void {
    if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..")) {
        return emitRangeFor(self, node, f);
    }
    const iter_t = try self.valueType(f.expr);
    if (self.state.for_is_cond.contains(f) or f.captures.len == 0 or iter_t.kind == .optional) {
        return emitCondFor(self, node, f);
    }
    return emitIterableFor(self, node, f);
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
    const elem_ir: ?ir.Type = if (self.recordedType(f.expr)) |t| switch (ir.peelDefined(t)) {
        .array => |arr| arr.elem.*,
        else => null,
    } else null;

    self.counter += 1;
    const id = self.counter;
    const iter_name = try std.fmt.allocPrint(a, "lls_iter_{d}", .{id});
    const zig_label = try loopZigLabel(self, f, id);

    const cap0_name = try self.localName(f.captures[0].name);
    const cap1_name = if (f.captures.len > 1) try self.localName(f.captures[1].name) else "";
    const raw1_name = try std.fmt.allocPrint(a, "lls_iter_i_{d}", .{id});

    const for_facts = self.state.for_capture_facts.get(node);
    const cap0_read = if (for_facts) |facts| facts[0].read else false;
    const cap1_read = if (for_facts) |facts| facts[1].read else false;
    const body = try forBody(self, node, f);

    try self.writeIndent();
    try self.writer.writeAll("{\n");
    self.indent += 1;
    try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ iter_name, iter_t.zig, try expr_mod.emitExpr(self, f.expr) });

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
        b.* = .{ .name = f.captures[0].name, .zig_name = cap0_name, .display = elem_t.display, .ir_type = elem_ir };
        try self.scopes.items[self.scopes.items.len - 1].put(f.captures[0].name, b);
    }
    if (f.captures.len > 1) {
        try self.writeIndent();
        try self.writer.print("const {s}: i64 = @intCast({s});\n", .{ cap1_name, raw1_name });
        const b = try a.create(Binding);
        b.* = .{ .name = f.captures[1].name, .zig_name = cap1_name, .display = "int", .ir_type = ir.TI64 };
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

    try emitStatements(self, body.statements);
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
    try emitStatements(self, block.statements);
    try self.emitDeferredAtScopeEnd(block.statements);
    self.popScope();
}

pub fn emitIfChain(self: *Emitter, node: *ast_mod.Node, i: *const ast_mod.If, first: bool) anyerror!void {
    if (i.pipe_value != null) return emitCaptureIfChain(self, node, i, first);

    const cond = try emitCondition(self, i.condition);
    if (first) try self.writeIndent();
    try self.writer.print("if ({s}) {{\n", .{cond});
    self.indent += 1;
    try emitIfBody(self, i.body);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    try emitIfElse(self, i.else_body);
}

pub fn emitCaptureIfChain(self: *Emitter, node: *ast_mod.Node, i: *const ast_mod.If, first: bool) anyerror!void {
    const a = self.arena.allocator();
    const cond_t = try self.valueType(i.condition);
    const is_error_union = cond_t.may_error and cond_t.kind != .error_value;
    if (!is_error_union and cond_t.kind != .optional) {
        return self.failAt(i.condition, "@if capture requires an optional or error-union value, got '{s}'", .{cond_t.display});
    }
    const payload = (if (is_error_union) cond_t.success else cond_t.payload) orelse {
        return self.failAt(i.condition, "native backend cannot determine the payload type of '{s}'", .{cond_t.display});
    };
    const payload_ir: ?ir.Type = if (self.recordedType(i.condition)) |t| blk: {
        if (is_error_union) {
            break :blk ir.unwrapError(self.state.typeAlloc(), t) catch null;
        } else {
            break :blk ir.optionalPayload(t);
        }
    } else null;
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
    const tmp_name = if (is_error_union)
        try std.fmt.allocPrint(a, "lls_ifres_{d}", .{id})
    else
        try std.fmt.allocPrint(a, "lls_ifopt_{d}", .{id});
    const cap_name = try self.localName(capture_name);

    // Key by the outer *ast.Node so the pointer is stable across traversal.
    const cap_facts = self.state.if_capture_facts.get(node);
    const cap_read = if (cap_facts) |f| f.read else false;
    const cap_assigned = if (cap_facts) |f| f.assigned else false;
    const cap_reassigned = if (cap_facts) |f| f.reassigned else false;

    if (first) try self.writeIndent();
    try self.writer.print("const {s}: {s} = {s};\n", .{ tmp_name, cond_t.zig, try expr_mod.emitExpr(self, i.condition) });
    if (first) try self.writeIndent();
    if (is_error_union) {
        try self.writer.print("if ({s} == .ok) {{\n", .{tmp_name});
        self.indent += 1;
        const kw = if (cap_reassigned or (cap_assigned and payload.kind != .pointer and payload.kind != .slice and payload.kind != .string)) "var" else "const";
        try self.writeIndent();
        try self.writer.print("{s} {s}: {s} = {s}.ok;\n", .{ kw, cap_name, payload.zig, tmp_name });
    } else {
        try self.writer.print("if ({s}) |{s}| {{\n", .{ tmp_name, cap_name });
        self.indent += 1;
    }
    self.pushScope();
    defer self.popScope();
    const b = try a.create(Binding);
    b.* = .{ .name = capture_name, .zig_name = cap_name, .display = payload.display, .ir_type = payload_ir };
    try self.scopes.items[self.scopes.items.len - 1].put(capture_name, b);
    if (!cap_read) {
        try self.writeIndent();
        if (cap_assigned) {
            try self.writer.print("_ = &{s};\n", .{cap_name});
        } else {
            try self.writer.print("_ = {s};\n", .{cap_name});
        }
    }
    const body = switch (i.body.*) {
        .block => |*blk| blk,
        else => return self.failAt(i.body, "native backend expects an @if block body", .{}),
    };
    try emitStatements(self, body.statements);
    try self.emitDeferredAtScopeEnd(body.statements);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    try emitIfElse(self, i.else_body);
}

pub fn emitIfElse(self: *Emitter, else_body: ?*ast_mod.Node) !void {
    if (else_body) |eb| {
        switch (eb.*) {
            .if_expr => |*nested| {
                if (nested.pipe_value != null) {
                    try self.writer.writeAll(" else {\n");
                    self.indent += 1;
                    try emitCaptureIfChain(self, eb, nested, true);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.writer.writeAll("}\n");
                } else {
                    try self.writer.writeAll(" else ");
                    try emitIfChain(self, eb, nested, false);
                }
            },
            .block => {
                try self.writer.writeAll(" else {\n");
                self.indent += 1;
                try emitIfBody(self, eb);
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
    try emitIfChain(self, node, i, true);
}

pub fn emitIfValue(self: *Emitter, node: *ast_mod.Node, i: *const ast_mod.If) ![]const u8 {
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
    try emitIfChain(self, node, i, true);
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    return std.fmt.allocPrint(a, "{s}: {{\n{s}", .{ zig_label, buf.items });
}

pub fn emitDefer(self: *Emitter, node: *ast_mod.Node, d: *const ast_mod.Defer) !void {
    if (self.defer_scopes.items.len == 0) {
        return self.failAt(node, "@defer outside a function", .{});
    }
    try self.defer_scopes.items[self.defer_scopes.items.len - 1].append(self.arena.allocator(), .{
        .body = d.body,
        .is_errdefer = d.is_errdefer,
    });
}

pub fn emitLineMarker(self: *Emitter, node: *ast_mod.Node) !void {
    if (self.options.release) return;
    const func_name = self.current_trace_func orelse return;
    const loc = node.loc();
    if (loc.line == 0) return;
    const file = if (loc.path.len > 0) loc.path else self.current_trace_file;
    const site_id = try self.addTraceSite(func_name, file, loc.line, loc.column);
    try self.writeIndent();
    try self.writer.print("ctx.setSite({d});\n", .{site_id});
}

/// Emit a machine-readable source marker so a failed Zig compile can be mapped
/// back to the LLTS statement that produced the generated code.
fn emitSourceSiteMarker(self: *Emitter, node: *ast_mod.Node) !void {
    const loc = node.loc();
    if (loc.line == 0) return;
    const file = if (loc.path.len > 0) loc.path else self.current_trace_file;
    try self.writeIndent();
    try self.writer.print("// llts-site {d} {d} {s}\n", .{ loc.line, loc.column, file });
}

pub fn emitLocalDeclaration(self: *Emitter, node: *ast_mod.Node, d: *const ast_mod.Declaration) !void {
    const a = self.arena.allocator();
    const info = if (self.infos.get(node)) |b| b else blk: {
        const b = try a.create(Binding);
        const fn_key: ?[]const u8 = blk_fn: {
            if (d.value.* == .primary and (d.value.primary.kind == .identifier or d.value.primary.kind == .register)) {
                if (self.state.functions.contains(d.value.primary.name)) break :blk_fn d.value.primary.name;
            }
            break :blk_fn null;
        };
        const module_path = if (fn_key == null) self.resolveModuleValue(d.value) else null;
        const facts = self.state.binding_facts.get(node) orelse state_mod.BindingFacts{};
        b.* = .{
            .name = d.name,
            .zig_name = "",
            .display = if (fn_key != null) "func" else if (module_path != null) "module" else self.displayForDeclValue(d) catch "unknown",
            .ir_type = if (fn_key != null or module_path != null) null else self.declaredIRType(d),
            .fn_key = fn_key,
            .module_path = module_path,
            .read = facts.read,
            .assigned = facts.assigned,
            .reassigned = facts.reassigned,
        };
        try self.infos.put(node, b);
        break :blk b;
    };
    // Function values and module namespaces are devirtualized at their call
    // sites; they have no Zig variable.
    if (info.fn_key != null or info.module_path != null) {
        try self.scopes.items[self.scopes.items.len - 1].put(d.name, info);
        return;
    }
    if (self.state.devirtualized_closures.get(node) orelse self.state.devirtualized_closures.get(d.value)) |cid| {
        if (self.state.closures.get(d.value)) |cinfo| {
            if (cinfo.captures.len > 0) {
                var fields_buf: std.ArrayList([]const u8) = .empty;
                for (cinfo.captures) |cap| {
                    const resolved = try self.lookupBinding(d.value, cap.name);
                    if (cap.is_mutated) {
                        const field_code = try std.fmt.allocPrint(a, ".{s} = @constCast(&({s}))", .{ cap.name, resolved.zig_name });
                        try fields_buf.append(a, field_code);
                    } else {
                        const field_code = try std.fmt.allocPrint(a, ".{s} = {s}", .{ cap.name, resolved.zig_name });
                        try fields_buf.append(a, field_code);
                    }
                }
                const fields_joined = try std.mem.join(a, ", ", fields_buf.items);
                try self.writeIndent();
                try self.writer.print("lls_env_stack_{d} = .{{ {s} }};\n", .{ cid, fields_joined });
            }
        }
        try self.scopes.items[self.scopes.items.len - 1].put(d.name, info);
        return;
    }
    const vt = try self.valTypeFor(node, info.ir_type, info.display);
    try self.requireValueType(node, vt);
    if (info.zig_name.len == 0) info.zig_name = try self.localName(d.name);

    const init_code = if (d.type_annotation != null)
        try expr_mod.emitDeclaredValue(self, d.value, vt)
    else
        try expr_mod.emitExpr(self, d.value);

    if (self.state.addr_taken_decls.contains(d.value)) {
        // The compiler recorded `&name` somewhere in this body, so the storage
        // must outlive the frame: the pointer may be stored into a field or
        // returned, and a Zig stack slot dies with the function. Box the value
        // in immortal heap and bind the name to the box pointer, so every later
        // use of the name (reads, writes, `&name`) goes through `name.*`.
        const cell = try std.fmt.allocPrint(a, "lls_box_{s}", .{info.zig_name});
        const ptr = try std.fmt.allocPrint(a, "lls_cell_{s}", .{info.zig_name});
        try self.writeIndent();
        try self.writer.print("const {s}: *{s} = blk: {{\n", .{ info.zig_name, vt.zig });
        try self.writeIndent();
        try self.writer.print("    const {s} = try ctx.allocImmortal(@sizeOf({s}), @alignOf({s}));\n", .{ cell, vt.zig, vt.zig });
        try self.writeIndent();
        try self.writer.print("    const {s}: *{s} = @ptrCast(@alignCast({s}.ptr));\n", .{ ptr, vt.zig, cell });
        try self.writeIndent();
        try self.writer.print("    {s}.* = {s};\n", .{ ptr, init_code });
        try self.writeIndent();
        try self.writer.print("    break :blk {s};\n", .{ptr});
        try self.writeIndent();
        try self.writer.writeAll("};\n");
        if (!info.read) {
            try self.writeIndent();
            try self.writer.print("_ = &{s};\n", .{info.zig_name});
        }
        info.zig_name = try std.fmt.allocPrint(a, "{s}.*", .{info.zig_name});
        try self.scopes.items[self.scopes.items.len - 1].put(d.name, info);
        return;
    }

    // Index stores into `[]byte` / string views don't reassign the slice header,
    // so Zig wants `const` (same as `.slice` / `.pointer`). Use `var` only when
    // the binding is actually reassigned.
    const needs_var = info.reassigned or (info.assigned and vt.kind != .pointer and vt.kind != .slice and vt.kind != .string);
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
    try emitStatements(self, block.statements);
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
    const zig_label = try loopZigLabel(self, f, id);

    const cap_name: []const u8 = if (f.captures.len > 0)
        try self.localName(f.captures[0].name)
    else
        try std.fmt.allocPrint(a, "lls_loop_i_{d}", .{id});

    const start = try expr_mod.emitI64Operand(self, f.expr.binary.left);
    const end = try expr_mod.emitI64Operand(self, f.expr.binary.right);

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
        b.* = .{
            .name = f.captures[0].name,
            .zig_name = cap_name,
            .display = "int",
            .ir_type = ir.TI64,
        };
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
    const body = try forBody(self, node, f);
    try emitStatements(self, body.statements);
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
        try emitStmt(self, s);
        if (self.state.terminates.get(s) orelse false) break;
    }
}

pub fn emitStmt(self: *Emitter, node: *ast_mod.Node) anyerror!void {
    try emitLineMarker(self, node);
    try emitSourceSiteMarker(self, node);
    switch (node.*) {
        .declaration => |*d| {
            if (root_mod.isImportDecl(d)) return;
            try emitLocalDeclaration(self, node, d);
        },
        .return_expr => |r| {
            if (r.return_value) |v| {
                if (self.cur_ret.kind == .void and !self.cur_ret.may_error) {
                    return self.failAt(v, "cannot return a value from a void function", .{});
                }
                try emitReturnValue(self, node, v);
            } else {
                if (self.cur_ret.kind != .void) {
                    return self.failAt(node, "missing return value for type '{s}'", .{self.cur_ret.display});
                }
                try self.emitDeferredFromDepth(0);
                try self.writeIndent();
                if (self.cur_ret.may_error) {
                    try self.writer.writeAll("return .{ .ok = {} };\n");
                } else {
                    try self.writer.writeAll("return;\n");
                }
            }
        },
        .block => |b| {
            try self.writeIndent();
            try self.writer.writeAll("{\n");
            self.indent += 1;
            self.pushScope();
            try emitStatements(self, b.statements);
            try self.emitDeferredAtScopeEnd(b.statements);
            self.popScope();
            self.indent -= 1;
            try self.writeIndent();
            try self.writer.writeAll("}\n");
        },
        .assignment => |*asn| try emitAssignment(self, node, asn),
        .if_expr => |i| try emitIfStmt(self, node, &i),
        .switch_expr => |sw| try emitSwitchStmt(self, node, &sw),
        .for_expr => |f| try emitForStmt(self, node, &f),
        .break_expr => |b| try emitBreak(self, node, &b),
        .continue_expr => |c| try emitContinue(self, node, &c),
        .defer_stmt => |d| try emitDefer(self, node, &d),
        .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
        else => try emitExprStatement(self, node),
    }
}

pub fn emitSwitchChain(self: *Emitter, sw: *const ast_mod.Switch, scrut: []const u8, scrut_t: ValType, first: bool, is_value: bool) !void {
    var wrote_any = false;
    var else_prong: ?ast_mod.SwitchProng = null;
    for (sw.prongs) |prong| {
        if (prong.is_else) {
            else_prong = prong;
            continue;
        }
        const cond = try emitSwitchCondition(self, prong.patterns, scrut, scrut_t);
        if (!wrote_any) {
            if (first) try self.writeIndent();
            try self.writer.print("if ({s}) {{\n", .{cond});
        } else {
            try self.writer.print(" else if ({s}) {{\n", .{cond});
        }
        self.indent += 1;
        try emitProngBody(self, prong.body);
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
        try emitProngBody(self, prong.body);
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}\n");
        return;
    } else if (is_value) {
        if (wrote_any) {
            try self.writer.writeAll(" else {\n");
        } else {
            if (first) try self.writeIndent();
            try self.writer.writeAll("{\n");
        }
        self.indent += 1;
        try self.writeIndent();
        try self.writer.writeAll("unreachable;\n");
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
        try conds.append(a, try emitEqualityCode(self, scrut, scrut_t, pat));
    }
    return std.mem.join(a, " or ", conds.items);
}

pub fn emitSwitchStmt(self: *Emitter, node: *ast_mod.Node, sw: *const ast_mod.Switch) !void {
    const vt = try switchScrutineeType(self, node, sw);
    const a = self.arena.allocator();
    self.counter += 1;
    const id = self.counter;
    const scrut_name = try std.fmt.allocPrint(a, "lls_scrut_{d}", .{id});
    const scrut_code = if (vt.kind == .error_value) try expr_mod.errorOperandCode(self, sw.condition) else try expr_mod.emitExpr(self, sw.condition);
    const wraps = switchContinueUsed(self, sw);
    try self.writeIndent();
    try self.writer.print("{s} {s}: {s} = {s};\n", .{
        if (wraps) "var" else "const", scrut_name, vt.zig, scrut_code,
    });
    if (!wraps) {
        try emitSwitchChain(self, sw, scrut_name, vt, true, false);
        return;
    }
    const loop_label = try std.fmt.allocPrint(a, "lls_sw_loop_{d}", .{id});
    try self.switch_targets.append(a, .{
        .label = sw.label.?,
        .zig_label = loop_label,
        .scrut_name = scrut_name,
        .scrut_type = vt,
        .scope_depth = self.scopes.items.len,
    });
    defer _ = self.switch_targets.pop();
    try self.writeIndent();
    try self.writer.print("{s}: while (true) {{\n", .{loop_label});
    self.indent += 1;
    try emitSwitchChain(self, sw, scrut_name, vt, true, false);
    try self.writeIndent();
    try self.writer.writeAll("break;\n");
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}\n");
}

pub fn emitBlockValue(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Block) ![]const u8 {
    const label = b.label orelse {
        return self.failAt(node, "value-producing block requires a label", .{});
    };
    const a = self.arena.allocator();
    const vt = try self.valueType(node);
    try self.requireValueType(node, vt);

    self.counter += 1;
    const zig_label = try std.fmt.allocPrint(a, "lls_blk_{d}", .{self.counter});
    try self.break_targets.append(a, .{
        .label = label,
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
    self.pushScope();
    try emitStatements(self, b.statements);
    self.popScope();
    self.indent -= 1;
    try self.writeIndent();
    try self.writer.writeAll("}");

    return std.fmt.allocPrint(a, "{s}: {{\n{s}", .{ zig_label, buf.items });
}

pub fn emitSwitchValue(self: *Emitter, node: *ast_mod.Node, sw: *const ast_mod.Switch) ![]const u8 {
    const a = self.arena.allocator();
    const vt = try switchScrutineeType(self, node, sw);
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

    const wraps = switchContinueUsed(self, sw);
    self.indent += 1;
    const scrut_code = if (vt.kind == .error_value) try expr_mod.errorOperandCode(self, sw.condition) else try expr_mod.emitExpr(self, sw.condition);
    try self.writeIndent();
    try self.writer.print("{s} {s}: {s} = {s};\n", .{
        if (wraps) "var" else "const", scrut_name, vt.zig, scrut_code,
    });
    if (wraps) {
        const loop_label = try std.fmt.allocPrint(a, "lls_sw_loop_{d}", .{id});
        try self.switch_targets.append(a, .{
            .label = sw.label.?,
            .zig_label = loop_label,
            .scrut_name = scrut_name,
            .scrut_type = vt,
            .scope_depth = self.scopes.items.len,
        });
        defer _ = self.switch_targets.pop();
        try self.writeIndent();
        try self.writer.print("{s}: while (true) {{\n", .{loop_label});
        self.indent += 1;
        try emitSwitchChain(self, sw, scrut_name, vt, true, true);
        try self.writeIndent();
        try self.writer.writeAll("break;\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}\n");
    } else {
        try emitSwitchChain(self, sw, scrut_name, vt, true, true);
    }
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

const JumpScanMode = enum { continue_label, plain_crossing };

const JumpScan = struct {
    label: []const u8 = "",
    mode: JumpScanMode,
    /// Number of generated switch-continue wrapper loops crossed so far.
    wrappers: usize = 0,
};

/// Does the labeled `@switch` use `continue :label`? Only such switches are
/// lowered to a wrapper loop (and only their wrapper labels are emitted).
fn switchContinueUsed(self: *Emitter, sw: *const ast_mod.Switch) bool {
    const label = sw.label orelse return false;
    for (sw.prongs) |prong| {
        var scan = JumpScan{ .label = label, .mode = .continue_label };
        if (scanJumps(self, prong.body, &scan)) return true;
    }
    return false;
}

/// Is there a plain `break`/`continue` in the loop body that would be captured
/// by a generated switch-continue wrapper and so needs an explicit Zig label?
fn loopNeedsSwitchLabel(self: *Emitter, body: *ast_mod.Node) bool {
    var scan = JumpScan{ .mode = .plain_crossing };
    return scanJumps(self, body, &scan);
}

/// Generate a Zig loop label when the loop is targeted by a labeled jump or
/// when a generated switch wrapper sits between it and a plain jump.
fn loopZigLabel(self: *Emitter, f: *const ast_mod.For, id: usize) !?[]const u8 {
    const used = if (f.label) |label| loopLabelUsed(self, f.body, label) else false;
    if (!used and !loopNeedsSwitchLabel(self, f.body)) return null;
    return try std.fmt.allocPrint(self.arena.allocator(), "lls_loop_{d}", .{id});
}

fn scanJumps(self: *Emitter, node: *ast_mod.Node, s: *JumpScan) bool {
    switch (node.*) {
        .continue_expr => |c| switch (s.mode) {
            .continue_label => return if (c.label) |l| std.mem.eql(u8, l, s.label) else false,
            .plain_crossing => return s.wrappers > 0 and c.label == null,
        },
        .break_expr => |b| {
            if (s.mode == .plain_crossing and s.wrappers > 0 and b.label == null and b.value == null) return true;
            if (b.value) |v| return scanJumps(self, v, s);
            return false;
        },
        .block => |b| {
            for (b.statements) |st| {
                if (scanJumps(self, st, s)) return true;
            }
            return false;
        },
        .switch_expr => |sw| {
            // An inner label with the same name shadows the one being scanned.
            if (s.mode == .continue_label and sw.label != null and std.mem.eql(u8, sw.label.?, s.label)) return false;
            if (scanJumps(self, sw.condition, s)) return true;
            var inner = s.*;
            if (s.mode == .plain_crossing and switchContinueUsed(self, &sw)) inner.wrappers += 1;
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| {
                    if (scanJumps(self, pat, s)) return true;
                }
                if (scanJumps(self, prong.body, &inner)) return true;
            }
            return false;
        },
        .for_expr => |f| {
            // A nested loop is a new target for plain `break`/`continue`.
            if (s.mode == .plain_crossing) return false;
            if (f.label != null and std.mem.eql(u8, f.label.?, s.label)) return false;
            if (scanJumps(self, f.expr, s)) return true;
            return scanJumps(self, f.body, s);
        },
        .return_expr => |r| {
            if (r.return_value) |v| return scanJumps(self, v, s);
            return false;
        },
        .defer_stmt => |d| return scanJumps(self, d.body, s),
        .declaration => |d| return scanJumps(self, d.value, s),
        .assignment => |asn| {
            if (scanJumps(self, asn.left, s)) return true;
            return scanJumps(self, asn.right, s);
        },
        .if_expr => |i| {
            if (scanJumps(self, i.condition, s)) return true;
            if (i.pipe_value) |v| {
                if (scanJumps(self, v, s)) return true;
            }
            if (scanJumps(self, i.body, s)) return true;
            if (i.else_body) |e| return scanJumps(self, e, s);
            return false;
        },
        .binary => |b| {
            if (scanJumps(self, b.left, s)) return true;
            return scanJumps(self, b.right, s);
        },
        .unary => |u| return scanJumps(self, u.arg, s),
        .call => |c| {
            if (scanJumps(self, c.callee, s)) return true;
            for (c.args) |arg| {
                if (scanJumps(self, arg, s)) return true;
            }
            return false;
        },
        .member => |m| {
            if (scanJumps(self, m.object, s)) return true;
            return scanJumps(self, m.property, s);
        },
        .index => |ix| {
            if (scanJumps(self, ix.object, s)) return true;
            if (ix.index) |v| {
                if (scanJumps(self, v, s)) return true;
            }
            if (ix.end) |v| {
                if (scanJumps(self, v, s)) return true;
            }
            if (ix.type_annotation) |v| return scanJumps(self, v, s);
            return false;
        },
        .array_literal => |al| {
            for (al.elements) |e| {
                if (scanJumps(self, e, s)) return true;
            }
            return false;
        },
        .try_expr => |t| return scanJumps(self, t.expression, s),
        .unwrap_expr => |u| return scanJumps(self, u.expression, s),
        .error_expr => |e| {
            for (e.args) |arg| {
                if (scanJumps(self, arg, s)) return true;
            }
            return false;
        },
        .struct_init => |si| {
            if (si.type_expr) |te| if (scanJumps(self, te, s)) return true;
            for (si.fields) |field| {
                if (scanJumps(self, field.value, s)) return true;
            }
            return false;
        },
        .comptime_expr => |ce| return scanJumps(self, ce.expr, s),
        else => return false,
    }
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
                if (loopLabelUsed(self, s, label)) return true;
            }
        },
        .declaration => |d| return loopLabelUsed(self, d.value, label),
        .return_expr => |r| {
            if (r.return_value) |v| return loopLabelUsed(self, v, label);
        },
        .defer_stmt => |d| return loopLabelUsed(self, d.body, label),
        .assignment => |asn| return loopLabelUsed(self, asn.right, label),
        .if_expr => |i| {
            if (loopLabelUsed(self, i.condition, label)) return true;
            if (i.pipe_value) |v| {
                if (loopLabelUsed(self, v, label)) return true;
            }
            if (loopLabelUsed(self, i.body, label)) return true;
            if (i.else_body) |e| return loopLabelUsed(self, e, label);
        },
        .switch_expr => |sw| {
            if (loopLabelUsed(self, sw.condition, label)) return true;
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| {
                    if (loopLabelUsed(self, pat, label)) return true;
                }
                if (loopLabelUsed(self, prong.body, label)) return true;
            }
        },
        .for_expr => |f| {
            if (loopLabelUsed(self, f.expr, label)) return true;
            if (loopLabelUsed(self, f.body, label)) return true;
        },
        .binary => |b| {
            if (loopLabelUsed(self, b.left, label)) return true;
            return loopLabelUsed(self, b.right, label);
        },
        .unary => |u| return loopLabelUsed(self, u.arg, label),
        .call => |c| {
            if (loopLabelUsed(self, c.callee, label)) return true;
            for (c.args) |arg| {
                if (loopLabelUsed(self, arg, label)) return true;
            }
        },
        .member => |m| {
            if (loopLabelUsed(self, m.object, label)) return true;
            return loopLabelUsed(self, m.property, label);
        },
        .index => |ix| {
            if (loopLabelUsed(self, ix.object, label)) return true;
            if (ix.index) |v| {
                if (loopLabelUsed(self, v, label)) return true;
            }
            if (ix.end) |v| {
                if (loopLabelUsed(self, v, label)) return true;
            }
            if (ix.type_annotation) |v| return loopLabelUsed(self, v, label);
        },
        .array_literal => |al| {
            for (al.elements) |e| {
                if (loopLabelUsed(self, e, label)) return true;
            }
        },
        .try_expr => |t| return loopLabelUsed(self, t.expression, label),
        .unwrap_expr => |u| return loopLabelUsed(self, u.expression, label),
        .error_expr => |e| {
            for (e.args) |arg| {
                if (loopLabelUsed(self, arg, label)) return true;
            }
        },
        .struct_init => |si| {
            if (si.type_expr) |te| if (loopLabelUsed(self, te, label)) return true;
            for (si.fields) |field| {
                if (loopLabelUsed(self, field.value, label)) return true;
            }
        },
        .comptime_expr => |ce| return loopLabelUsed(self, ce.expr, label),
        else => {},
    }
    return false;
}

pub fn switchScrutineeType(self: *Emitter, node: *ast_mod.Node, sw: *const ast_mod.Switch) !ValType {
    const vt = try self.valueType(sw.condition);
    if (vt.may_error and vt.kind != .error_value) {
        return self.failAt(node, "error-union value must be handled with '?' before @switch", .{});
    }
    if (vt.isByteSequence()) return vt;
    switch (vt.kind) {
        .int, .float, .bool, .string, .error_value => {},
        else => return self.failAt(node, "native backend does not support @switch on '{s}' yet", .{vt.display}),
    }
    return vt;
}

fn isStringLiteralExpr(node: *ast_mod.Node) bool {
    return node.* == .literal and node.literal.literal_type == .string;
}
