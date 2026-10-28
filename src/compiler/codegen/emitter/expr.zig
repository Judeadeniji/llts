const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const widths = @import("../../widths.zig");
const root_mod = @import("root.zig");
const Emitter = root_mod.Emitter;
const ValType = root_mod.ValType;

pub fn emitBinary(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Binary) ![]const u8 {
    const a = self.arena.allocator();
    const op = b.operator;
    if (std.mem.eql(u8, op, "|>")) return emitPipe(self, b);
    if (std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "||")) {
        const lt = try self.valueType(b.left);
        const rt = try self.valueType(b.right);
        if (lt.kind != .bool or rt.kind != .bool) {
            return self.failAt(node, "logical '{s}' requires boolean operands", .{op});
        }
        const zig_op = if (std.mem.eql(u8, op, "&&")) "and" else "or";
        return std.fmt.allocPrint(a, "({s} {s} {s})", .{ try self.emitExpr(b.left), zig_op, try self.emitExpr(b.right) });
    }

    if (std.mem.eql(u8, op, "+") and (try self.isStringy(b.left) or try self.isStringy(b.right))) {
        const lt = try self.valueType(b.left);
        const rt = try self.valueType(b.right);
        if (lt.kind != .string or rt.kind != .string) {
            return self.failAt(node, "string concatenation requires two string operands", .{});
        }
        return std.fmt.allocPrint(a, "(try rt.mem.concat(ctx, {s}, {s}))", .{
            try self.emitExpr(b.left),
            try self.emitExpr(b.right),
        });
    }

    if (isComparison(op)) return self.emitComparison(node, b);

    const lt = try self.valueType(b.left);
    const rt = try self.valueType(b.right);
    if (lt.may_error or rt.may_error) {
        return self.failAt(node, "error-union operand must be handled with '?' first", .{});
    }
    if (lt.kind == .int and rt.kind == .int) return self.emitIntBinary(node, b, lt);
    if (lt.kind == .float or rt.kind == .float) return self.emitFloatBinary(node, b, lt, rt);
    return self.failAt(node, "native backend (Phase 2) does not support '{s}' on '{s}' and '{s}'", .{
        op, lt.display, rt.display,
    });
}

/// `lhs |> f(a)` emits as the ordinary call `f(lhs, a)`: the left operand
/// becomes the callee's first argument. Pure desugaring — no runtime support.
/// The synthetic call is keyed on the right-hand node so generic-call and
/// diagnostic lookups match what typecheck recorded for it.
fn emitPipe(self: *Emitter, b: *const ast_mod.Binary) ![]const u8 {
    const a = self.arena.allocator();
    const right = b.right;
    const callee: *ast_mod.Node = if (right.* == .call) right.call.callee else right;
    const explicit: []const *ast_mod.Node = if (right.* == .call) right.call.args else &.{};
    const args = try a.alloc(*ast_mod.Node, explicit.len + 1);
    args[0] = b.left;
    @memcpy(args[1..], explicit);
    const synth = ast_mod.Call{ .callee = callee, .args = args, .loc = right.loc() };
    return self.emitCall(right, &synth);
}

pub fn emitCall(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Call) anyerror![]const u8 {
    const a = self.arena.allocator();

    if (c.callee.* == .primary and std.mem.startsWith(u8, c.callee.primary.name, "@")) {
        const intrinsic = c.callee.primary.name;
        if (std.mem.eql(u8, intrinsic, "@as")) {
            if (c.args.len != 2) return self.failAt(node, "@as expects 2 arguments", .{});
            const target = try self.valueType(node);
            if (target.kind == .other or target.kind == .void) {
                return self.failAt(node, "native backend (Phase 2) does not support @as to '{s}'", .{target.display});
            }
            return self.emitStrongCoercion(c.args[1], target);
        }
        if (std.mem.eql(u8, intrinsic, "len")) {
            if (c.args.len != 1) return self.failAt(node, "len expects 1 argument", .{});
            const at = try self.valueType(c.args[0]);
            if (at.kind != .string) {
                return self.failAt(node, "len of '{s}' is not supported in Phase 2", .{at.display});
            }
            return std.fmt.allocPrint(a, "@as(i64, @intCast(({s}).len))", .{try self.emitExpr(c.args[0])});
        }
        return self.failAt(node, "native backend (Phase 2) does not support intrinsic '{s}'", .{intrinsic});
    }

    if (c.callee.* != .primary) {
        return self.failAt(node, "native backend (Phase 2) only supports direct function calls", .{});
    }
    const callee = c.callee.primary.name;

    if (std.mem.eql(u8, callee, "print")) {
        var args_buf: std.ArrayList([]const u8) = .empty;
        for (c.args) |arg| {
            const at = try self.valueType(arg);
            if (at.may_error) {
                return self.failAt(arg, "error-union print argument must be handled with '?' first", .{});
            }
            try args_buf.append(a, try self.emitStrongCoercion(arg, at));
        }
        const args_joined = try std.mem.join(a, ", ", args_buf.items);
        return std.fmt.allocPrint(a, "(try rt.print.print(ctx, .{{{s}}}))", .{args_joined});
    }

    if (std.mem.eql(u8, callee, "len")) {
        if (c.args.len != 1) return self.failAt(node, "len expects 1 argument", .{});
        const at = try self.valueType(c.args[0]);
        if (at.may_error) {
            return self.failAt(c.args[0], "error-union len argument must be handled with '?' first", .{});
        }
        if (at.kind != .string) {
            return self.failAt(node, "len of '{s}' is not supported in Phase 2", .{at.display});
        }
        return std.fmt.allocPrint(a, "@as(i64, @intCast(({s}).len))", .{try self.emitExpr(c.args[0])});
    }

    var target_name: ?[]const u8 = null;
    if (self.state.generic_calls.get(node)) |gc| target_name = gc.instance;
    if (target_name == null and self.state.functions.contains(callee)) target_name = callee;
    const name = target_name orelse {
        return self.failAt(node, "native backend cannot resolve function '{s}' (imports are Phase 3)", .{callee});
    };
    if (self.reach) |*r| {
        if (!r.isFunctionReachable(name)) {
            return self.failAt(node, "internal: function '{s}' not marked reachable", .{name});
        }
    }

    var args_buf: std.ArrayList([]const u8) = .empty;
    for (c.args) |arg| {
        const at = try self.valueType(arg);
        if (at.may_error) {
            return self.failAt(arg, "error-union argument must be handled with '?' first", .{});
        }
        try args_buf.append(a, try self.emitExpr(arg));
    }
    const args_joined = try std.mem.join(a, ", ", args_buf.items);
    const zig_fn = try self.fnName(name);
    if (args_joined.len == 0) {
        return std.fmt.allocPrint(a, "(try {s}(ctx))", .{zig_fn});
    }
    return std.fmt.allocPrint(a, "(try {s}(ctx, {s}))", .{ zig_fn, args_joined });
}

pub fn emitComparison(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Binary) ![]const u8 {
    const a = self.arena.allocator();
    const op = b.operator;
    const lt = try self.valueType(b.left);
    const rt = try self.valueType(b.right);
    if (lt.may_error or rt.may_error) {
        return self.failAt(node, "error-union operand must be handled with '?' first", .{});
    }

    const eq = std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=");
    if (eq) {
        const negate = std.mem.eql(u8, op, "!=");
        if (lt.kind == .string and rt.kind == .string) {
            const base = try std.fmt.allocPrint(a, "rt.arith.eqStr({s}, {s})", .{
                try self.emitExpr(b.left), try self.emitExpr(b.right),
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt.kind == .bool and rt.kind == .bool) {
            const base = try std.fmt.allocPrint(a, "rt.arith.eqBool({s}, {s})", .{
                try self.emitExpr(b.left), try self.emitExpr(b.right),
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt.kind == .int and rt.kind == .int) {
            const base = try std.fmt.allocPrint(a, "rt.arith.eqI64({s}, {s})", .{
                try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt.kind == .float and rt.kind == .float) {
            const l = try self.emitF64Operand(b.left);
            const r = try self.emitF64Operand(b.right);
            const base = try std.fmt.allocPrint(a, "rt.arith.eqF64({s}, {s})", .{ l, r });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        return self.failAt(node, "cannot compare '{s}' with '{s}'", .{ lt.display, rt.display });
    }

    if (lt.kind == .int and rt.kind == .int) {
        const fn_name = switch (op[0]) {
            '<' => if (op.len == 1) "ltI64" else "leI64",
            '>' => if (op.len == 1) "gtI64" else "geI64",
            else => return self.failAt(node, "unsupported comparison '{s}'", .{op}),
        };
        return std.fmt.allocPrint(a, "rt.arith.{s}({s}, {s})", .{
            fn_name, try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
        });
    }
    if (lt.kind == .float or rt.kind == .float) {
        const use_f32 = std.mem.eql(u8, lt.zig, "f32") and std.mem.eql(u8, rt.zig, "f32");
        const suffix: []const u8 = if (use_f32) "F32" else "F64";
        const prefix = switch (op[0]) {
            '<' => if (op.len == 1) "lt" else "le",
            '>' => if (op.len == 1) "gt" else "ge",
            else => return self.failAt(node, "unsupported comparison '{s}'", .{op}),
        };
        const fn_name = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, suffix });
        const l = if (use_f32) try self.emitF32Operand(b.left) else try self.emitF64Operand(b.left);
        const r = if (use_f32) try self.emitF32Operand(b.right) else try self.emitF64Operand(b.right);
        return std.fmt.allocPrint(a, "rt.arith.{s}({s}, {s})", .{ fn_name, l, r });
    }
    return self.failAt(node, "cannot order '{s}' and '{s}'", .{ lt.display, rt.display });
}

pub fn emitExpr(self: *Emitter, node: *ast_mod.Node) anyerror![]const u8 {
    switch (node.*) {
        .literal => |lit| return self.emitLiteral(node, lit),
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) {
                return self.failAt(node, "native backend (Phase 2) does not support '{s}' operands", .{@tagName(p.kind)});
            }
            const resolved = try self.lookupBinding(node, p.name);
            return resolved.zig_name;
        },
        .binary => |b| return self.emitBinary(node, &b),
        .unary => |u| return self.emitUnary(node, &u),
        .call => |c| return self.emitCall(node, &c),
        .try_expr => |t| {
            if (t.expression.* != .call) {
                return self.failAt(node, "native backend (Phase 2) only supports '?' on direct calls", .{});
            }
            return self.emitExpr(t.expression);
        },
        .if_expr => |i| return self.emitIfValue(node, &i),
        .switch_expr => |sw| return self.emitSwitchValue(node, &sw),
        .declaration, .return_expr, .block, .for_expr, .break_expr, .continue_expr, .defer_stmt, .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {
            return self.failAt(node, "native backend (Phase 2) does not support {s} in expression position", .{@tagName(node.*)});
        },
        else => {
            return self.failAt(node, "native backend (Phase 2) does not support {s} yet", .{@tagName(node.*)});
        },
    }
}

pub fn emitF32Operand(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const t = try self.valueType(node);
    if (t.may_error) return self.failAt(node, "error-union value must be handled with '?' first", .{});
    const code = try self.emitExpr(node);
    if (t.kind == .float) {
        if (std.mem.eql(u8, t.zig, "f64")) return std.fmt.allocPrint(a, "@as(f32, @floatCast({s}))", .{code});
        return code;
    }
    if (t.kind == .int) {
        if (isBareIntLiteral(node)) return code;
        return std.fmt.allocPrint(a, "@as(f32, @floatFromInt({s}))", .{code});
    }
    return self.failAt(node, "expected a numeric operand, got '{s}'", .{t.display});
}

pub fn emitF64Operand(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const t = try self.valueType(node);
    if (t.may_error) return self.failAt(node, "error-union value must be handled with '?' first", .{});
    const code = try self.emitExpr(node);
    if (t.kind == .float) {
        if (std.mem.eql(u8, t.zig, "f32")) return std.fmt.allocPrint(a, "@as(f64, @floatCast({s}))", .{code});
        return code;
    }
    if (t.kind == .int) {
        if (isBareIntLiteral(node)) return code;
        return std.fmt.allocPrint(a, "@as(f64, @floatFromInt({s}))", .{code});
    }
    return self.failAt(node, "expected a numeric operand, got '{s}'", .{t.display});
}

pub fn emitFloatBinary(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Binary, lt: ValType, rt: ValType) ![]const u8 {
    const a = self.arena.allocator();
    if (lt.kind != .float or rt.kind != .float) {
        return self.failAt(node, "mixed integer/float arithmetic is not supported yet", .{});
    }
    const use_f32 = std.mem.eql(u8, lt.zig, "f32") and std.mem.eql(u8, rt.zig, "f32");
    const suffix: []const u8 = if (use_f32) "F32" else "F64";
    const l = if (use_f32) try self.emitF32Operand(b.left) else try self.emitF64Operand(b.left);
    const r = if (use_f32) try self.emitF32Operand(b.right) else try self.emitF64Operand(b.right);
    const op = b.operator;
    if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or
        std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**"))
    {
        const base = switch (op[0]) {
            '+' => "add",
            '-' => "sub",
            '*' => "mul",
            else => "pow",
        };
        return std.fmt.allocPrint(a, "(rt.arith.{s}{s}({s}, {s}))", .{ base, suffix, l, r });
    }
    if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
        const base = if (std.mem.eql(u8, op, "/")) "div" else "mod";
        return std.fmt.allocPrint(a, "(try rt.arith.{s}{s}({s}, {s}))", .{ base, suffix, l, r });
    }
    return self.failAt(node, "native backend (Phase 2) does not support '{s}' on floats", .{op});
}

pub fn emitI64Operand(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const t = try self.valueType(node);
    if (t.may_error) return self.failAt(node, "error-union value must be handled with '?' first", .{});
    if (t.kind != .int) return self.failAt(node, "expected an integer operand, got '{s}'", .{t.display});
    const code = try self.emitExpr(node);
    if (t.isU64()) return std.fmt.allocPrint(a, "@as(i64, @bitCast({s}))", .{code});
    return code;
}

pub fn emitIntBinary(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Binary, lt: ValType) ![]const u8 {
    const a = self.arena.allocator();
    const op = b.operator;
    const w = lt.width orelse return self.failAt(node, "missing integer width", .{});

    var checked_call: ?[]const u8 = null;
    var plain_call: ?[]const u8 = null;
    const wrap_needed = !(w == .i64 or w == .isize);

    if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*")) {
        const base = switch (op[0]) {
            '+' => "add",
            '-' => "sub",
            else => "mul",
        };
        if (!wrap_needed) {
            plain_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}({s}, {s}))", .{
                base, try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
            });
        } else {
            checked_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}Checked(.{s}, {s}, {s}))", .{
                base, @tagName(w), try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
            });
        }
    } else if (std.mem.eql(u8, op, "+%") or std.mem.eql(u8, op, "-%") or std.mem.eql(u8, op, "*%")) {
        const base = switch (op[0]) {
            '+' => "add",
            '-' => "sub",
            else => "mul",
        };
        plain_call = try std.fmt.allocPrint(a, "(rt.arith.{s}Wrapped(.{s}, {s}, {s}))", .{
            base, @tagName(w), try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
        });
    } else if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
        const base = if (std.mem.eql(u8, op, "/")) "div" else "rem";
        plain_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}({s}, {s}))", .{
            base, try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
        });
    } else if (std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**")) {
        plain_call = try std.fmt.allocPrint(a, "(rt.arith.pow({s}, {s}))", .{
            try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
        });
    } else if (std.mem.eql(u8, op, "&") or std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "~")) {
        const base = switch (op[0]) {
            '&' => "band",
            '|' => "bor",
            else => "bxor",
        };
        plain_call = try std.fmt.allocPrint(a, "(rt.arith.{s}({s}, {s}))", .{
            base, try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
        });
    } else if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) {
        const base = if (std.mem.eql(u8, op, "<<")) "shl" else "shr";
        plain_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}({s}, {s}))", .{
            base, try self.emitI64Operand(b.left), try self.emitI64Operand(b.right),
        });
    } else {
        return self.failAt(node, "native backend (Phase 2) does not support operator '{s}'", .{op});
    }

    const call = checked_call orelse plain_call.?;
    return self.wrapWidth(lt, call);
}

pub fn emitLiteral(self: *Emitter, node: *ast_mod.Node, lit: ast_mod.Literal) ![]const u8 {
    switch (lit.literal_type) {
        .string => return self.zigString(lit.value),
        .boolean => return lit.value,
        .number, .hex, .octal, .binary => return lit.value,
        .null => return self.failAt(node, "native backend (Phase 2) does not support null values yet", .{}),
    }
}

pub fn emitStrongCoercion(self: *Emitter, node: *ast_mod.Node, target: ValType) ![]const u8 {
    const a = self.arena.allocator();
    if (node.* == .literal) {
        const code = try self.emitExpr(node);
        if (target.kind == .int and isIntLiteral(node)) {
            return std.fmt.allocPrint(a, "@as({s}, {s})", .{ target.zig, code });
        }
        if (target.kind == .float and isNumericLiteral(node)) {
            return std.fmt.allocPrint(a, "@as({s}, {s})", .{ target.zig, code });
        }
        // String literals are already string-compatible in Zig (print
        // accepts pointer-to-array, annotated slots coerce to []const u8).
    }
    return self.emitValueCoercedForce(node, target);
}

pub fn emitUnary(self: *Emitter, node: *ast_mod.Node, u: *const ast_mod.Unary) ![]const u8 {
    const a = self.arena.allocator();
    if (std.mem.eql(u8, u.operator, "const")) return self.emitExpr(u.arg);
    if (std.mem.eql(u8, u.operator, "&")) {
        return self.failAt(node, "native backend (Phase 2) does not support address-of yet", .{});
    }
    const t = try self.valueType(u.arg);
    if (t.may_error) {
        return self.failAt(u.arg, "error-union value must be handled with '?' first", .{});
    }
    if (std.mem.eql(u8, u.operator, "!")) {
        if (t.kind != .bool) {
            return self.failAt(node, "'!' requires a boolean operand, got '{s}'", .{t.display});
        }
        return std.fmt.allocPrint(a, "(!{s})", .{try self.emitExpr(u.arg)});
    }
    if (std.mem.eql(u8, u.operator, "-")) {
        if (t.kind == .float) {
            const fn_name = if (std.mem.eql(u8, t.zig, "f32")) "negF32" else "negF64";
            return std.fmt.allocPrint(a, "(rt.arith.{s}({s}))", .{ fn_name, try self.emitExpr(u.arg) });
        }
        if (t.kind != .int) {
            return self.failAt(node, "unary '-' requires a numeric operand", .{});
        }
        if (t.isI64()) {
            return std.fmt.allocPrint(a, "(try rt.arith.neg({s}))", .{try self.emitExpr(u.arg)});
        }
        const inner = try std.fmt.allocPrint(a, "(try rt.arith.neg({s}))", .{try self.emitI64Operand(u.arg)});
        return self.wrapWidth(t, inner);
    }
    if (std.mem.eql(u8, u.operator, "~")) {
        if (t.kind != .int) {
            return self.failAt(node, "unary '~' requires an integer operand", .{});
        }
        if (t.isI64()) {
            return std.fmt.allocPrint(a, "(rt.arith.bnot({s}))", .{try self.emitExpr(u.arg)});
        }
        const inner = try std.fmt.allocPrint(a, "(rt.arith.bnot({s}))", .{try self.emitI64Operand(u.arg)});
        return self.wrapWidth(t, inner);
    }
    return self.failAt(node, "native backend does not support unary '{s}'", .{u.operator});
}

pub fn emitValueCoerced(self: *Emitter, node: *ast_mod.Node, target: ValType) ![]const u8 {
    return self.emitValueCoercedMode(node, target, false);
}

pub fn emitValueCoercedForce(self: *Emitter, node: *ast_mod.Node, target: ValType) ![]const u8 {
    return self.emitValueCoercedMode(node, target, true);
}

pub fn emitValueCoercedMode(self: *Emitter, node: *ast_mod.Node, target: ValType, force: bool) ![]const u8 {
    const a = self.arena.allocator();
    const src = try self.valueType(node);
    if (src.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' first", .{});
    }
    if (target.may_error and target.kind == .other) {
        return self.failAt(node, "native backend does not support error-union values yet", .{});
    }
    const code = try self.emitExpr(node);

    // Literals are already polymorphic; the surrounding declaration,
    // assignment, return, print, or @as supplies the concrete type.
    if (node.* == .literal) return code;

    if (src.kind == target.kind and src.zig.len == target.zig.len and
        std.mem.eql(u8, src.zig, target.zig))
    {
        return code;
    }
    if (target.kind == .int and src.kind == .int) {
        if (src.isU64() and target.isI64()) return std.fmt.allocPrint(a, "@as(i64, @bitCast({s}))", .{code});
        if (src.isI64() and target.isU64()) return std.fmt.allocPrint(a, "@as(u64, @bitCast({s}))", .{code});
        if (!force and src.width != null and target.width != null and
            widths.isWidening(src.width.?, target.width.?))
        {
            return code;
        }
        return std.fmt.allocPrint(a, "@as({s}, @intCast({s}))", .{ target.zig, code });
    }
    if (target.kind == .float and src.kind == .float) {
        if (!force and std.mem.eql(u8, src.zig, "f32") and std.mem.eql(u8, target.zig, "f64")) return code;
        return std.fmt.allocPrint(a, "@as({s}, @floatCast({s}))", .{ target.zig, code });
    }
    if (target.kind == .float and src.kind == .int) {
        return std.fmt.allocPrint(a, "@as({s}, @floatFromInt({s}))", .{ target.zig, code });
    }
    if (target.kind == .void and src.kind == .void) return code;
    if (target.kind == .bool and src.kind == .bool) return code;
    if (target.kind == .string and src.kind == .string) return code;
    return self.failAt(node, "cannot assign '{s}' to '{s}' in native emission", .{ src.display, target.display });
}

pub fn f64Code(self: *Emitter, code: []const u8, t: ValType) ![]const u8 {
    if (std.mem.eql(u8, t.zig, "f32")) {
        return std.fmt.allocPrint(self.arena.allocator(), "@as(f64, @floatCast({s}))", .{code});
    }
    return code;
}

pub fn i64Code(self: *Emitter, code: []const u8, t: ValType) ![]const u8 {
    if (t.isU64()) return std.fmt.allocPrint(self.arena.allocator(), "@as(i64, @bitCast({s}))", .{code});
    return code;
}

pub fn isStringy(self: *Emitter, node: *ast_mod.Node) !bool {
    const t = try self.valueType(node);
    return t.kind == .string;
}

pub fn wrapWidth(self: *Emitter, t: ValType, expr: []const u8) ![]const u8 {
    const a = self.arena.allocator();
    if (t.isI64()) return expr;
    if (t.isU64()) return std.fmt.allocPrint(a, "@as(u64, @bitCast({s}))", .{expr});
    if (t.kind == .bool) return std.fmt.allocPrint(a, "({s} != 0)", .{expr});
    return std.fmt.allocPrint(a, "@as({s}, @intCast({s}))", .{ t.zig, expr });
}

pub fn isComparison(op: []const u8) bool {
    return std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=");
}

pub fn isBareIntLiteral(node: *ast_mod.Node) bool {
    return isIntLiteral(node);
}

pub fn isIntLiteral(node: *ast_mod.Node) bool {
    if (node.* != .literal) return false;
    const lit = node.literal;
    return switch (lit.literal_type) {
        .number => std.mem.indexOfScalar(u8, lit.value, '.') == null and
            std.mem.indexOfScalar(u8, lit.value, 'e') == null and
            std.mem.indexOfScalar(u8, lit.value, 'E') == null,
        .hex, .octal, .binary => true,
        else => false,
    };
}

pub fn isNumericLiteral(node: *ast_mod.Node) bool {
    if (node.* != .literal) return false;
    return switch (node.literal.literal_type) {
        .number, .hex, .octal, .binary => true,
        else => false,
    };
}
