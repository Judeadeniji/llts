const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const widths = @import("../../widths.zig");
const root_mod = @import("root.zig");
const Emitter = root_mod.Emitter;
const ValType = root_mod.ValType;
const MemberTarget = root_mod.MemberTarget;

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
            if (at.kind != .string and at.kind != .slice and at.kind != .array) {
                return self.failAt(node, "len of '{s}' is not supported in Phase 3", .{at.display});
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
            if (containsStruct(at)) {
                return self.failAt(arg, "native backend cannot print struct values yet; print fields individually", .{});
            }
            if (at.kind == .null_value) {
                try args_buf.append(a, std.fmt.allocPrint(a, "@as(?u8, {s})", .{try self.emitExpr(arg)}) catch unreachable);
                continue;
            }
            try args_buf.append(a, try self.emitStrongCoercion(arg, at));
        }
        const args_joined = try std.mem.join(a, ", ", args_buf.items);
        return std.fmt.allocPrint(a, "(try rt.print.print(ctx, .{{{s}}}))", .{args_joined});
    }

    if (std.mem.eql(u8, callee, "len")) {
        if (c.args.len != 1) return self.failAt(node, "len expects 1 argument", .{});
        var at = try self.valueType(c.args[0]);
        var operand = try self.emitExpr(c.args[0]);
        if (at.kind == .pointer) {
            const payload = at.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{at.display});
            at = payload.*;
            operand = try std.fmt.allocPrint(a, "({s}).*", .{operand});
        }
        if (at.may_error) {
            return self.failAt(c.args[0], "error-union len argument must be handled with '?' first", .{});
        }
        if (at.kind != .string and at.kind != .slice and at.kind != .array) {
            return self.failAt(node, "len of '{s}' is not supported in Phase 3", .{at.display});
        }
        return std.fmt.allocPrint(a, "@as(i64, @intCast(({s}).len))", .{operand});
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
        .member => |m| return self.emitMember(node, &m),
        .index => |ix| return self.emitIndex(node, &ix),
        .array_literal => |al| return self.emitArrayLiteral(node, &al, try self.valueType(node)),
        .struct_init => |si| return self.emitStructLiteral(node, &si, try self.valueType(node)),
        .unwrap_expr => |u| return self.emitOptionalUnwrap(node, &u),
        .comptime_expr => |ce| return self.emitExpr(ce.expr),
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
    _ = node;
    switch (lit.literal_type) {
        .string => return self.zigString(lit.value),
        .boolean => return lit.value,
        .number, .hex, .octal, .binary => return lit.value,
        .null => return "null",
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

pub fn emitAddressOf(self: *Emitter, node: *ast_mod.Node, arg: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    switch (arg.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) {
                return self.failAt(node, "native backend only supports '&' on place expressions", .{});
            }
            const target = try self.lookupBinding(node, p.name);
            return std.fmt.allocPrint(a, "@constCast(&{s})", .{target.zig_name});
        },
        .member, .index => {
            var buf: std.ArrayList(u8) = .empty;
            const old_writer = self.writer;
            self.writer = buf.writer(a).any();
            const place = self.emitPlaceLvalue(arg) catch |err| {
                self.writer = old_writer;
                return err;
            };
            self.writer = old_writer;
            return std.fmt.allocPrint(a, "blk: {{\n{s}    break :blk @constCast(&({s}));\n}}", .{ buf.items, place });
        },
        else => return self.failAt(node, "native backend only supports '&' on place expressions", .{}),
    }
}

pub fn emitUnary(self: *Emitter, node: *ast_mod.Node, u: *const ast_mod.Unary) ![]const u8 {
    const a = self.arena.allocator();
    if (std.mem.eql(u8, u.operator, "const")) return self.emitExpr(u.arg);
    if (std.mem.eql(u8, u.operator, "&")) {
        return self.emitAddressOf(node, u.arg);
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
    if (node.* == .array_literal and target.kind == .array) {
        return self.emitArrayLiteral(node, &node.array_literal, target);
    }
    if (node.* == .array_literal and target.kind == .slice) {
        return self.emitSliceLiteral(node, &node.array_literal, target);
    }
    if (node.* == .struct_init and target.kind == .struct_) {
        return self.emitStructLiteral(node, &node.struct_init, target);
    }
    const code = try self.emitExpr(node);

    // Literals are already polymorphic; the surrounding declaration,
    // assignment, return, print, or @as supplies the concrete type.
    if (node.* == .literal and !isNullLiteral(node)) return code;

    if (src.kind == .slice and target.kind == .slice and
        (node.* == .primary or node.* == .member))
    {
        return self.emitCloneSlice(node, src, code);
    }

    if (target.kind == .optional) {
        if (src.kind == .null_value) return "null";
        if (src.kind == .optional and std.mem.eql(u8, src.zig, target.zig)) return code;
        if (src.kind == .other) {
            return self.failAt(node, "cannot assign '{s}' to '{s}' in native emission", .{ src.display, target.display });
        }
        return code;
    }
    if (target.kind == .null_value) {
        if (src.kind == .null_value) return "null";
        return self.failAt(node, "cannot assign '{s}' to 'null'", .{src.display});
    }
    if (target.kind == .slice and src.kind == .array) {
        return self.emitArrayToSlice(node, src, target, code);
    }

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
    if (target.kind == .struct_ and src.kind == .struct_) return code;
    if (target.kind == .array and src.kind == .array) return code;
    if (target.kind == .slice and src.kind == .slice) return code;
    if (target.kind == .pointer and src.kind == .pointer) return code;
    return self.failAt(node, "cannot assign '{s}' to '{s}' in native emission", .{ src.display, target.display });
}

pub fn isNullLiteral(node: *ast_mod.Node) bool {
    if (node.* != .literal) return false;
    return node.literal.literal_type == .null;
}

pub fn containsStruct(t: ValType) bool {
    return switch (t.kind) {
        .struct_ => true,
        .array, .slice => if (t.elem) |e| containsStruct(e.*) else false,
        .optional, .pointer => if (t.payload) |p| containsStruct(p.*) else false,
        else => false,
    };
}

pub fn resolveMemberField(self: *Emitter, node: *ast_mod.Node, m: *const ast_mod.Member) !?MemberTarget {
    if (m.property.* != .primary) return null;
    const field_name = m.property.primary.name;
    const obj_t = try self.valueType(m.object);
    const info = (try self.structInfoForDisplay(m.object, obj_t.display)) orelse return null;
    const index = info.field_index.get(field_name) orelse {
        return self.failAt(m.property, "native backend cannot resolve field '{s}'", .{field_name});
    };
    _ = node;
    return .{ .info = info, .index = index };
}

pub fn emitMemberAccess(self: *Emitter, node: *ast_mod.Node, m: *const ast_mod.Member) ![]const u8 {
    const target = (try self.resolveMemberField(node, m)) orelse {
        return self.failAt(node, "native backend cannot lower member access '.{s}' yet", .{
            if (m.property.* == .primary) m.property.primary.name else "?",
        });
    };
    const obj_t = try self.valueType(m.object);
    const field = target.info.fields[target.index];
    const deref: []const u8 = if (obj_t.kind == .pointer) ".*" else "";
    return std.fmt.allocPrint(self.arena.allocator(), "({s}){s}.{s}", .{
        try self.emitExpr(m.object), deref, field.zig_name,
    });
}

pub fn emitMember(self: *Emitter, node: *ast_mod.Node, m: *const ast_mod.Member) ![]const u8 {
    if (m.object.* == .primary and m.property.* == .primary) {
        if (self.state.enums.get(m.object.primary.name)) |ed| {
            const variant = m.property.primary.name;
            if (ed.string_values) |values| {
                if (values.get(variant)) |s| return self.zigString(s);
            }
            const value = ed.variants.get(variant) orelse {
                return self.failAt(node, "native backend cannot resolve enum variant '{s}'", .{variant});
            };
            return std.fmt.allocPrint(self.arena.allocator(), "{d}", .{value});
        }
    }
    return self.emitMemberAccess(node, m);
}

pub fn emitIndex(self: *Emitter, node: *ast_mod.Node, ix: *const ast_mod.Index) ![]const u8 {
    if (ix.is_slice) return self.emitSlice(node, ix);

    const a = self.arena.allocator();
    var obj_t = try self.valueType(ix.object);
    var object_expr = try self.emitExpr(ix.object);
    if (obj_t.kind == .pointer) {
        const payload = obj_t.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{obj_t.display});
        obj_t = payload.*;
        object_expr = try std.fmt.allocPrint(a, "({s}).*", .{object_expr});
    }
    const word: []const u8 = switch (obj_t.kind) {
        .string => "String",
        .slice => "Slice",
        .array => "Array",
        else => return self.failAt(node, "native backend cannot index '{s}' yet", .{obj_t.display}),
    };
    const use: []const u8 = switch (obj_t.kind) {
        .string => "str",
        .slice => "slice",
        else => "arr",
    };
    const index_node = ix.index orelse return self.failAt(node, "expected index expression", .{});
    const index_code = try self.emitI64Operand(index_node);

    self.counter += 1;
    const id = self.counter;
    const obj_name = try std.fmt.allocPrint(a, "lls_idx_obj_{d}", .{id});
    const idx_name = try std.fmt.allocPrint(a, "lls_idx_{d}", .{id});
    const fmt = try std.fmt.allocPrint(a, "{s} index out of bounds: {{d}} (len {{d}}); use len({s})", .{ word, use });
    return std.fmt.allocPrint(a,
        \\blk: {{
        \\    const {s}: {s} = {s};
        \\    const {s}: i64 = {s};
        \\    if ({s} < 0 or {s} >= @as(i64, @intCast({s}.len))) return rt.io.fail({s}, .{{ {s}, @as(i64, @intCast({s}.len)) }});
        \\    break :blk {s}[@intCast({s})];
        \\}}
    , .{
        obj_name,       obj_t.zig,   object_expr,
        idx_name,       index_code,
        idx_name,       idx_name,    obj_name,
        try self.zigString(fmt),
        idx_name,       obj_name,
        obj_name,       idx_name,
    });
}

pub fn emitSlice(self: *Emitter, node: *ast_mod.Node, ix: *const ast_mod.Index) ![]const u8 {
    const a = self.arena.allocator();
    const obj_t = try self.valueType(ix.object);
    if (obj_t.kind != .string and obj_t.kind != .slice and obj_t.kind != .array) {
        return self.failAt(node, "native backend cannot slice '{s}' yet", .{obj_t.display});
    }
    self.counter += 1;
    const id = self.counter;
    const obj_name = try std.fmt.allocPrint(a, "lls_slice_obj_{d}", .{id});
    const lo_name = try std.fmt.allocPrint(a, "lls_slice_lo_{d}", .{id});
    const hi_name = try std.fmt.allocPrint(a, "lls_slice_hi_{d}", .{id});

    const lo_code = if (ix.index) |idx| try self.emitI64Operand(idx) else "0";
    const hi_code = if (ix.end) |end|
        try self.emitI64Operand(end)
    else
        try std.fmt.allocPrint(a, "@as(i64, @intCast({s}.len))", .{obj_name});

    return std.fmt.allocPrint(a,
        \\blk: {{
        \\    const {s}: {s} = {s};
        \\    const {s}: i64 = {s};
        \\    const {s}: i64 = {s};
        \\    if ({s} < 0 or {s} < {s} or {s} > @as(i64, @intCast({s}.len))) return rt.io.fail("Slice out of bounds: [{{d}}..{{d}}] (len {{d}})", .{{ {s}, {s}, @as(i64, @intCast({s}.len)) }});
        \\    break :blk {s}[@intCast({s})..@intCast({s})];
        \\}}
    , .{
        obj_name, obj_t.zig, try self.emitExpr(ix.object),
        lo_name,  lo_code,
        hi_name,  hi_code,
        lo_name,  hi_name, lo_name, hi_name, obj_name,
        lo_name,  hi_name, obj_name,
        obj_name, lo_name, hi_name,
    });
}

pub fn emitArrayLiteral(self: *Emitter, node: *ast_mod.Node, al: *const ast_mod.ArrayLiteral, target: ValType) ![]const u8 {
    const a = self.arena.allocator();
    if (target.kind != .array or target.elem == null or target.array_len == null) {
        return self.failAt(node, "native backend needs a fixed array type for this array literal", .{});
    }
    const elem = target.elem.?;
    if (al.elements.len != target.array_len.?) {
        return self.failAt(node, "array literal length does not match '{s}'", .{target.display});
    }
    var parts: std.ArrayList([]const u8) = .empty;
    for (al.elements) |element| {
        try parts.append(a, try self.emitValueCoerced(element, elem.*));
    }
    if (parts.items.len == 0) {
        return std.fmt.allocPrint(a, "{s}{{}}", .{target.zig});
    }
    const joined = try std.mem.join(a, ", ", parts.items);
    return std.fmt.allocPrint(a, "{s}{{ {s} }}", .{ target.zig, joined });
}

pub fn emitCloneSlice(self: *Emitter, node: *ast_mod.Node, src: ValType, src_code: []const u8) ![]const u8 {
    const a = self.arena.allocator();
    const elem = src.elem orelse {
        return self.failAt(node, "native backend cannot determine the slice element type", .{});
    };
    self.counter += 1;
    const id = self.counter;
    const src_name = try std.fmt.allocPrint(a, "lls_slice_src_{d}", .{id});
    const buf_name = try std.fmt.allocPrint(a, "lls_slice_clone_buf_{d}", .{id});
    const dst_name = try std.fmt.allocPrint(a, "lls_slice_clone_dst_{d}", .{id});
    const item_name = try std.fmt.allocPrint(a, "lls_slice_item_{d}", .{id});
    const i_name = try std.fmt.allocPrint(a, "lls_slice_i_{d}", .{id});
    return std.fmt.allocPrint(a,
        \\blk: {{
        \\    const {s}: {s} = {s};
        \\    const {s} = try rt.mem.allocArray(ctx, {s}.len, @sizeOf({s}), @alignOf({s}));
        \\    const {s}: [*]{s} = @ptrCast(@alignCast({s}.ptr));
        \\    for ({s}, 0..) |{s}, {s}| {s}[{s}] = {s};
        \\    break :blk {s}[0..{s}.len];
        \\}}
    , .{
        src_name, src.zig, src_code,
        buf_name, src_name, elem.zig, elem.zig,
        dst_name, elem.zig, buf_name,
        src_name, item_name, i_name, dst_name, i_name, item_name,
        dst_name, src_name,
    });
}

pub fn emitArrayToSlice(self: *Emitter, node: *ast_mod.Node, src: ValType, target: ValType, src_code: []const u8) ![]const u8 {
    const a = self.arena.allocator();
    const elem = target.elem orelse {
        return self.failAt(node, "native backend cannot determine the slice element type", .{});
    };
    const len = src.array_len orelse {
        return self.failAt(node, "native backend cannot determine the array length", .{});
    };
    self.counter += 1;
    const id = self.counter;
    const src_name = try std.fmt.allocPrint(a, "lls_arrcopy_src_{d}", .{id});
    const buf_name = try std.fmt.allocPrint(a, "lls_arrcopy_buf_{d}", .{id});
    const dst_name = try std.fmt.allocPrint(a, "lls_arrcopy_dst_{d}", .{id});
    return std.fmt.allocPrint(a,
        \\blk: {{
        \\    const {s}: {s} = {s};
        \\    const {s} = try rt.mem.allocArray(ctx, {d}, @sizeOf({s}), @alignOf({s}));
        \\    const {s}: *[{d}]{s} = @ptrCast(@alignCast({s}.ptr));
        \\    {s}.* = {s};
        \\    break :blk {s}[0..{d}];
        \\}}
    , .{
        src_name, src.zig, src_code,
        buf_name, len, elem.zig, elem.zig,
        dst_name, len, elem.zig, buf_name,
        dst_name, src_name,
        dst_name, len,
    });
}

pub fn emitSliceLiteral(self: *Emitter, node: *ast_mod.Node, al: *const ast_mod.ArrayLiteral, target: ValType) ![]const u8 {
    const a = self.arena.allocator();
    const elem = target.elem orelse {
        return self.failAt(node, "native backend cannot determine the slice element type", .{});
    };
    var parts: std.ArrayList([]const u8) = .empty;
    for (al.elements) |element| {
        try parts.append(a, try self.emitValueCoerced(element, elem.*));
    }
    const joined = if (parts.items.len == 0) "" else try std.mem.join(a, ", ", parts.items);
    self.counter += 1;
    const id = self.counter;
    const buf_name = try std.fmt.allocPrint(a, "lls_slice_buf_{d}", .{id});
    const arr_name = try std.fmt.allocPrint(a, "lls_slice_arr_{d}", .{id});
    return std.fmt.allocPrint(a,
        \\blk: {{
        \\    const {s} = try rt.mem.allocArray(ctx, {d}, @sizeOf({s}), @alignOf({s}));
        \\    const {s}: *[{d}]{s} = @ptrCast(@alignCast({s}.ptr));
        \\    {s}.* = [{d}]{s}{{ {s} }};
        \\    break :blk {s}[0..{d}];
        \\}}
    , .{
        buf_name, al.elements.len, elem.zig, elem.zig,
        arr_name, al.elements.len, elem.zig, buf_name,
        arr_name, al.elements.len, elem.zig, joined,
        arr_name, al.elements.len,
    });
}

pub fn emitStructLiteral(self: *Emitter, node: *ast_mod.Node, si: *const ast_mod.StructInit, target: ValType) ![]const u8 {
    const a = self.arena.allocator();
    if (target.kind != .struct_) {
        return self.failAt(node, "native backend needs a struct type for this initializer", .{});
    }
    const info = try self.ensureStructType(node, target.display);
    var parts: std.ArrayList([]const u8) = .empty;
    for (info.fields) |field| {
        var provided: ?*ast_mod.Node = null;
        for (si.fields) |init_field| {
            if (std.mem.eql(u8, init_field.name, field.name)) {
                provided = init_field.value;
                break;
            }
        }
        const code = if (provided) |value|
            try self.emitValueCoerced(value, field.vt)
        else
            try self.zeroValue(field.vt);
        try parts.append(a, try std.fmt.allocPrint(a, ".{s} = {s}", .{ field.zig_name, code }));
    }
    if (parts.items.len == 0) {
        return std.fmt.allocPrint(a, "{s}{{}}", .{info.zig_name});
    }
    const joined = try std.mem.join(a, ", ", parts.items);
    return std.fmt.allocPrint(a, "{s}{{ {s} }}", .{ info.zig_name, joined });
}

pub fn emitOptionalUnwrap(self: *Emitter, node: *ast_mod.Node, u: *const ast_mod.UnwrapExpr) ![]const u8 {
    _ = node;
    const vt = try self.valueType(u.expression);
    if (vt.kind != .optional) return self.emitExpr(u.expression);
    return std.fmt.allocPrint(self.arena.allocator(), "({s} orelse return rt.io.fail(\"Attempted to unwrap null\"))", .{
        try self.emitExpr(u.expression),
    });
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
