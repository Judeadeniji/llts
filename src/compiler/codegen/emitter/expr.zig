const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const state_mod = @import("../../state.zig");
const path_mod = @import("../../expr/path.zig");
const from_ast = @import("../../typecheck/from_ast.zig");
const ir = @import("../../typecheck/ir.zig");
const widths = @import("../../widths.zig");
const intrinsics_mod = @import("../../intrinsics.zig");
const root_mod = @import("root.zig");
const unit_mod = @import("unit.zig");
const stmt_mod = @import("stmt.zig");
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
        return std.fmt.allocPrint(a, "({s} {s} {s})", .{ try emitExpr(self, b.left), zig_op, try emitExpr(self, b.right) });
    }

    if (std.mem.eql(u8, op, "+") and (try isStringy(self, b.left) or try isStringy(self, b.right) or try isStringBufferPtr(self, b.left) or try isStringBufferPtr(self, b.right))) {
        return self.failAt(node, "string concatenation requires @concat(allocator, a, b) or @concat(buffer, a, b); '+' no longer concatenates strings", .{});
    }

    if (isComparison(op)) return emitComparison(self, node, b);

    const lt = try self.valueType(b.left);
    const rt = try self.valueType(b.right);
    if (lt.may_error or rt.may_error) {
        return self.failAt(node, "error-union operand must be handled with '?' first", .{});
    }
    if (isBitwiseOp(op) or isShiftOp(op)) {
        // Preserve the expression's own width (the left operand's type, or an
        // untyped literal's i64). Operands are widened only for the runtime
        // helper; the result is narrowed back before any destination coercion.
        if (!(lt.kind == .int or lt.kind == .bool) or !(rt.kind == .int or rt.kind == .bool)) {
            return self.failAt(node, "native backend: '{s}' requires integer operands, got '{s}' and '{s}'", .{
                op, lt.display, rt.display,
            });
        }
        const vt = try self.valueType(node);
        if (vt.kind != .int and vt.kind != .bool) {
            return self.failAt(node, "native backend: '{s}' requires an integer result, got '{s}'", .{ op, vt.display });
        }
        return emitIntBinary(self, node, b, vt);
    }
    if (lt.kind == .int and rt.kind == .int) return emitIntBinary(self, node, b, lt);
    if (lt.kind == .float or rt.kind == .float) return emitFloatBinary(self, node, b, lt, rt);
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
    return emitCall(self, right, &synth);
}

fn calleeParamValType(self: *Emitter, func_name: []const u8, arg_idx: usize) ?ValType {
    const def = self.state.functions.get(func_name) orelse return null;
    if (def.param_irs) |pirs| {
        if (arg_idx < pirs.len) {
            return self.valTypeOfIR(def.node, pirs[arg_idx]) catch null;
        }
        return null;
    }
    if (def.node.* != .function_decl) return null;
    const f = &def.node.function_decl;
    const params = switch (f.params.*) {
        .params => |p| p.params,
        else => return null,
    };
    if (arg_idx >= params.len) return null;
    const p = params[arg_idx];
    const p_ann = p.type_annotation orelse return null;
    const ta = self.state.typeAlloc();
    const tir = from_ast.typeFromAst(p_ann, self.state, ta) catch return null;
    return self.valTypeFromIR(p_ann, tir) catch null;
}

fn emitCallArguments(
    self: *Emitter,
    node: *ast_mod.Node,
    func_name: []const u8,
    args: []*ast_mod.Node,
    param_offset: usize,
    args_buf: *std.ArrayList([]const u8),
) !void {
    const a = self.arena.allocator();
    const def = self.state.functions.get(func_name);
    const is_variadic = if (def) |d| d.is_variadic else false;
    const rest_ir = if (def) |d| d.rest_ir else null;
    const named_param_count: usize = if (def) |d|
        (if (d.param_irs) |pirs| (if (pirs.len > param_offset) pirs.len - param_offset else 0) else 0)
    else blk: {
        if (def == null or def.?.node.* != .function_decl) break :blk args.len;
        const f = &def.?.node.function_decl;
        const plist = switch (f.params.*) {
            .params => |p| p.params,
            else => break :blk args.len,
        };
        const total = if (is_variadic and plist.len > 0) plist.len - 1 else plist.len;
        break :blk if (total > param_offset) total - param_offset else 0;
    };

    if (!is_variadic) {
        for (args, 0..) |arg, i| {
            const param_vt = calleeParamValType(self, func_name, i + param_offset);
            if (param_vt) |pt| {
                try args_buf.append(a, try emitValueCoerced(self, arg, pt));
            } else {
                try args_buf.append(a, try emitExpr(self, arg));
            }
        }
        return;
    }

    // Variadic call: emit named arguments first
    var i: usize = 0;
    while (i < named_param_count and i < args.len) : (i += 1) {
        const param_vt = calleeParamValType(self, func_name, i + param_offset);
        if (param_vt) |pt| {
            try args_buf.append(a, try emitValueCoerced(self, args[i], pt));
        } else {
            try args_buf.append(a, try emitExpr(self, args[i]));
        }
    }

    // Trailing arguments: pack into stack slice &[_]T{ ... }
    var rest_elem_vt: ?ValType = null;
    if (rest_ir) |rir| {
        if (rir == .array) {
            rest_elem_vt = try self.valTypeOfIR(node, rir.array.elem.*);
        }
    }
    if (rest_elem_vt == null and def != null and def.?.node.* == .function_decl) {
        const f = &def.?.node.function_decl;
        const plist = switch (f.params.*) {
            .params => |p| p.params,
            else => &[_]ast_mod.Param{},
        };
        if (plist.len > 0 and plist[plist.len - 1].is_rest) {
            const last_p = plist[plist.len - 1];
            if (last_p.type_annotation) |ann| {
                const ta = self.state.typeAlloc();
                const tir = from_ast.typeFromAst(ann, self.state, ta) catch null;
                if (tir) |t| {
                    const elem = if (t == .array) t.array.elem.* else t;
                    rest_elem_vt = try self.valTypeOfIR(node, elem);
                }
            }
        }
    }

    const elem_vt = rest_elem_vt orelse {
        return self.failAt(node, "native backend cannot determine rest parameter element type for '{s}'", .{func_name});
    };

    var rest_items: std.ArrayList([]const u8) = .empty;
    while (i < args.len) : (i += 1) {
        const val_code = try emitValueCoerced(self, args[i], elem_vt);
        try rest_items.append(a, val_code);
    }

    const rest_slice = try std.fmt.allocPrint(a, "&[_]{s}{{{s}}}", .{
        elem_vt.zig,
        try std.mem.join(a, ", ", rest_items.items),
    });
    try args_buf.append(a, rest_slice);
}

pub fn emitCall(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Call) anyerror![]const u8 {
    const a = self.arena.allocator();

    if (self.state.type_call_results.get(node)) |disp| {
        return self.zigString(disp);
    }

    if (c.callee.* == .primary and std.mem.startsWith(u8, c.callee.primary.name, "@")) {
        const intrinsic = c.callee.primary.name;
        if (std.mem.eql(u8, intrinsic, "@asm")) {
            if (c.inline_asm != null) return emitExtendedAsm(self, node, c);
            if (c.args.len != 1) return self.failAt(node, "@asm expects 1 argument", .{});
            const template = c.args[0];
            if (template.* != .literal or template.literal.literal_type != .string) {
                return self.failAt(template, "@asm expects a string literal template", .{});
            }
            return std.fmt.allocPrint(a, "asm volatile ({s})", .{
                try self.zigString(template.literal.value),
            });
        }
        if (std.mem.eql(u8, intrinsic, "@isError")) {
            if (c.args.len != 1) return self.failAt(node, "@isError expects 1 argument", .{});
            const t = try self.valueType(c.args[0]);
            if (t.may_error and t.kind != .error_value) {
                self.counter += 1;
                const id = self.counter;
                const res_name = try std.fmt.allocPrint(a, "lls_iseres_{d}", .{id});
                return std.fmt.allocPrint(a,
                    \\blk: {{
                    \\    const {s}: {s} = {s};
                    \\    break :blk switch ({s}) {{ .ok => false, .err => true }};
                    \\}}
                , .{ res_name, t.zig, try emitExpr(self, c.args[0]), res_name });
            }
            const has_effects = exprHasEffects(c.args[0]);
            if (t.kind == .error_value) {
                if (!has_effects) return "true";
                return std.fmt.allocPrint(a, "blk: {{ _ = {s}; break :blk true; }}", .{try emitExpr(self, c.args[0])});
            }
            if (t.kind == .void or t.kind == .null_value) return "false";
            if (!has_effects) return "false";
            return std.fmt.allocPrint(a, "blk: {{ _ = {s}; break :blk false; }}", .{try emitExpr(self, c.args[0])});
        }
        if (std.mem.eql(u8, intrinsic, "@new")) {
            return self.failAt(
                node,
                "@new is not part of the native core language; native allocation will move to the standard library",
                .{},
            );
        }
        if (std.mem.eql(u8, intrinsic, "@addrOf")) {
            if (c.args.len != 1) return self.failAt(node, "@addrOf expects 1 argument", .{});
            const ptr = try addrOfPointerCode(self, node, c.args[0]);
            return std.fmt.allocPrint(a, "@as(i64, @intCast(@intFromPtr({s})))", .{ptr});
        }
        if (std.mem.eql(u8, intrinsic, "@typeOf")) {
            if (c.args.len != 1) return self.failAt(node, "@typeOf expects 1 argument", .{});
            const disp = self.state.type_of_results.get(node) orelse "unknown";
            return self.zigString(disp);
        }
        if (std.mem.eql(u8, intrinsic, "@sizeOf")) {
            if (c.args.len != 1) return self.failAt(node, "@sizeOf expects 1 argument", .{});
            if (self.state.size_of_results.get(node)) |size| {
                return std.fmt.allocPrint(a, "@as(i64, {d})", .{size});
            }
            return self.failAt(node, "native backend cannot determine @sizeOf statically", .{});
        }
        if (std.mem.eql(u8, intrinsic, "@nameOf")) {
            if (c.args.len != 1) return self.failAt(node, "@nameOf expects 1 argument", .{});
            const plan = self.state.name_of_plans.get(node) orelse {
                return self.failAt(node, "native backend cannot resolve @nameOf", .{});
            };
            return switch (plan) {
                .fold => |spelling| self.zigString(spelling),
                .decl_name => |spelling| self.zigString(spelling),
                .error_code => std.fmt.allocPrint(a, "({s}).message", .{try errorOperandCode(self, c.args[0])}),
                .enum_type => |ename| emitNameOfEnum(self, node, ename, c.args[0]),
            };
        }
        if (std.mem.eql(u8, intrinsic, "@as")) {
            if (c.args.len != 2) return self.failAt(node, "@as expects 2 arguments", .{});
            const target = try self.valueType(node);
            if (target.kind == .other or target.kind == .void) {
                return self.failAt(node, "native backend (Phase 2) does not support @as to '{s}'", .{target.display});
            }
            return emitStrongCoercion(self, c.args[1], target);
        }
        if (std.mem.eql(u8, intrinsic, "@concat")) {
            if (c.args.len != 3) return self.failAt(node, "@concat expects (allocator|buffer, a, b)", .{});
            const dest_t = try self.valueType(c.args[0]);
            const a_code = try emitExpr(self, c.args[1]);
            const b_code = try emitExpr(self, c.args[2]);
            // Buffer form: first arg is a caller-owned `*[]u8` / `*[]byte`.
            if (dest_t.kind == .pointer and dest_t.payload != null and (dest_t.payload.?.kind == .string or dest_t.payload.?.kind == .slice)) {
                return std.fmt.allocPrint(a, "(try rt.mem.concatInto(@constCast(({s}).*), {s}, {s}))", .{
                    try emitExpr(self, c.args[0]), a_code, b_code,
                });
            }
            // Allocator form: dest is evaluated for effect then ignored (until #16);
            // operands are stringified (template holes, ints, …) into the frame.
            // Unique label — templates nest `@concat` and Zig rejects reused `blk:`.
            self.counter += 1;
            const label = try std.fmt.allocPrint(a, "lls_concat_{d}", .{self.counter});
            return std.fmt.allocPrint(a, "{s}: {{ _ = {s}; break :{s} (try rt.print.concatDisplay(ctx, {s}, {s})); }}", .{
                label, try emitExpr(self, c.args[0]), label, a_code, b_code,
            });
        }
        if (std.mem.eql(u8, intrinsic, "len")) {
            if (c.args.len != 1) return self.failAt(node, "len expects 1 argument", .{});
            const at = try self.valueType(c.args[0]);
            if (at.kind != .string and at.kind != .slice and at.kind != .array) {
                return self.failAt(node, "len of '{s}' is not supported in Phase 3", .{at.display});
            }
            return std.fmt.allocPrint(a, "@as(i64, @intCast(({s}).len))", .{try emitExpr(self, c.args[0])});
        }
        return self.failAt(node, "native backend (Phase 2) does not support intrinsic '{s}'", .{intrinsic});
    }

    if (c.callee.* == .member) {
        // Module exports resolve by static path; struct methods by receiver type.
        if (try emitModuleCall(self, node, c)) |code| return code;
        if (try emitMethodCall(self, node, c)) |code| return code;
    }

    if (c.callee.* != .primary and c.callee.* != .call) {
        return self.failAt(node, "native backend (Phase 2) only supports direct function calls", .{});
    }
    // A `.call` callee is a devirtualized function call (`f()()`), recorded in
    // `state.call_targets`; it has no builtin name.
    const callee: []const u8 = if (c.callee.* == .primary) c.callee.primary.name else "";

    if (std.mem.eql(u8, callee, "print")) {
        var args_buf: std.ArrayList([]const u8) = .empty;
        for (c.args) |arg| {
            if (arg.* == .call and arg.call.callee.* == .primary and
                std.mem.eql(u8, arg.call.callee.primary.name, "@addrOf"))
            {
                if (arg.call.args.len != 1) return self.failAt(arg, "@addrOf expects 1 argument", .{});
                const ptr = try addrOfPointerCode(self, arg, arg.call.args[0]);
                try args_buf.append(a, try std.fmt.allocPrint(a, "rt.print.Addr{{ .value = @intFromPtr({s}) }}", .{ptr}));
                continue;
            }
            const at = try self.valueType(arg);
            if (at.kind == .struct_ or
                (at.kind == .pointer and at.payload != null and at.payload.?.kind == .struct_))
            {
                var object = try emitExpr(self, arg);
                if (at.kind == .pointer) {
                    object = try std.fmt.allocPrint(a, "({s}).*", .{object});
                }
                const info = (try self.structInfoForValType(arg, at)) orelse {
                    return self.failAt(arg, "native backend cannot resolve struct type '{s}'", .{at.display});
                };
                try args_buf.append(a, try std.fmt.allocPrint(a, "rt.print.Struct{{ .bytes = &lls_bytes_{s}({s}) }}", .{
                    info.zig_name, object,
                }));
                continue;
            }
            // Pointers are not printable values — require an explicit `@as(T, ptr)`
            // (or `@addrOf` above). Do not auto-deref; that would hide the load.
            if (at.kind == .pointer) {
                const pointee = if (at.payload) |p| p.display else "T";
                return self.failAt(arg, "cannot print pointer type '{s}'; use @as({s}, ...) to load the pointee", .{ at.display, pointee });
            }
            if (containsStruct(at)) {
                return self.failAt(arg, "native backend cannot print aggregates containing structs yet; print fields individually", .{});
            }
            if (at.kind == .null_value) {
                try args_buf.append(a, std.fmt.allocPrint(a, "@as(?u8, {s})", .{try emitExpr(self, arg)}) catch unreachable);
                continue;
            }
            try args_buf.append(a, try emitStrongCoercion(self, arg, at));
        }
        const args_joined = try std.mem.join(a, ", ", args_buf.items);
        return std.fmt.allocPrint(a, "(try rt.print.print(ctx, .{{{s}}}))", .{args_joined});
    }

    if (std.mem.eql(u8, callee, "len")) {
        if (c.args.len != 1) return self.failAt(node, "len expects 1 argument", .{});
        var at = try self.valueType(c.args[0]);
        var operand = try emitExpr(self, c.args[0]);
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
    if (self.state.call_targets.get(node)) |t| {
        target_name = t.key;
    } else if (self.state.call_targets.get(c.callee)) |t| {
        target_name = t.key;
    } else if (self.state.generic_calls.get(node)) |gc| {
        target_name = gc.instance;
    } else if (c.callee.* == .primary and self.state.functions.contains(c.callee.primary.name)) {
        target_name = c.callee.primary.name;
    }
    const name = target_name orelse {
        return self.failAt(node, "native backend cannot resolve function '{s}' (function values must be called directly)", .{callee});
    };
    if (self.reach) |r| {
        if (!r.isFunctionReachable(name)) {
            return self.failAt(node, "internal: function '{s}' not marked reachable", .{name});
        }
    }

    var args_buf: std.ArrayList([]const u8) = .empty;
    const r_args = self.runtimeArgs(node, c);
    try emitCallArguments(self, node, name, r_args, 0, &args_buf);
    const args_joined = try std.mem.join(a, ", ", args_buf.items);
    const zig_fn = try self.fnName(name);
    if (args_joined.len == 0) {
        return std.fmt.allocPrint(a, "(try {s}(ctx))", .{zig_fn});
    }
    return std.fmt.allocPrint(a, "(try {s}(ctx, {s}))", .{ zig_fn, args_joined });
}

fn emitExtendedAsm(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Call) ![]const u8 {
    const spec = c.inline_asm orelse return self.failAt(node, "internal: missing @asm specification", .{});
    const result_type = try self.valueType(node);
    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(self.arena.allocator());

    try writer.writeAll(if (spec.is_volatile) "asm volatile (" else "asm (");
    try writer.writeAll(try self.zigString(spec.template));
    try writer.writeAll("\n    : ");
    for (spec.outputs, 0..) |output, i| {
        if (i > 0) try writer.writeAll(",\n      ");
        try writer.print("[{s}] {s} (", .{ output.name, try self.zigString(output.constraint) });
        if (output.return_type != null) {
            try writer.print("-> {s}", .{result_type.zig});
        } else {
            const arg_index = output.arg_index orelse {
                return self.failAt(node, "internal: missing @asm output target", .{});
            };
            try writer.writeAll(try stmt_mod.emitPlaceLvalue(self, c.args[arg_index]));
        }
        try writer.writeByte(')');
    }

    try writer.writeAll("\n    : ");
    for (spec.inputs, 0..) |input, i| {
        if (i > 0) try writer.writeAll(",\n      ");
        try writer.print("[{s}] {s} ({s})", .{
            input.name,
            try self.zigString(input.constraint),
            try emitExpr(self, c.args[input.arg_index]),
        });
    }

    try writer.writeAll("\n    : .{");
    for (spec.clobbers, 0..) |clobber, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print(" .{s} = true", .{clobber});
    }
    if (spec.clobbers.len > 0) try writer.writeByte(' ');
    try writer.writeAll("})");
    return buf.toOwnedSlice(self.arena.allocator());
}

/// `mod.fn(args)` / `mod.sub.fn(args)` — emits a direct call to a module export.
fn emitModuleCall(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Call) !?[]const u8 {
    const a = self.arena.allocator();
    const target = self.state.call_targets.get(node) orelse self.state.call_targets.get(c.callee) orelse return null;
    if (target.receiver_mode != .none) return null;
    const name = target.key;
    if (!self.state.functions.contains(name)) return null;
    if (self.reach) |r| {
        if (!r.isFunctionReachable(name)) {
            return self.failAt(node, "internal: function '{s}' not marked reachable", .{name});
        }
    }
    var args_buf: std.ArrayList([]const u8) = .empty;
    const r_args = self.runtimeArgs(node, c);
    try emitCallArguments(self, node, name, r_args, 0, &args_buf);
    const zig_fn = try self.fnName(name);
    if (args_buf.items.len == 0) {
        return try std.fmt.allocPrint(a, "(try {s}(ctx))", .{zig_fn});
    }
    return try std.fmt.allocPrint(a, "(try {s}(ctx, {s}))", .{ zig_fn, try std.mem.join(a, ", ", args_buf.items) });
}

/// `obj.method(args)` — resolves `Type::method` and emits a direct call with
/// the receiver prepended. Returns null when the callee is not a struct method
/// (fields and module exports fall through to the generic path).
fn emitMethodCall(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Call) !?[]const u8 {
    const a = self.arena.allocator();
    const m = &c.callee.member;
    if (m.property.* != .primary) return null;
    const target = (self.methodTarget(c.callee) catch null) orelse return null;
    if (self.reach) |r| {
        if (!r.isFunctionReachable(target.key)) {
            return self.failAt(node, "internal: function '{s}' not marked reachable", .{target.key});
        }
    }

    var args_buf: std.ArrayList([]const u8) = .empty;
    switch (target.mode) {
        .none => {},
        .value => try args_buf.append(a, try emitExpr(self, m.object)),
        .pointer => {
            if (target.receiver_is_pointer) {
                try args_buf.append(a, try emitExpr(self, m.object));
            } else if (Emitter.isPlaceNode(m.object)) {
                // Locals are `const` in emitted Zig unless reassigned; the LLTS
                // const rules already rejected mutating a `@const` receiver, so
                // taking the address here is sound.
                const lvalue = try stmt_mod.emitPlaceLvalue(self, m.object);
                try args_buf.append(a, try std.fmt.allocPrint(a, "@constCast(&({s}))", .{lvalue}));
            } else {
                self.counter += 1;
                try args_buf.append(a, try std.fmt.allocPrint(
                    a,
                    "blk: {{ var lls_recv_{d} = {s}; break :blk &lls_recv_{d}; }}",
                    .{ self.counter, try emitExpr(self, m.object), self.counter },
                ));
            }
        },
    }
    const r_args = self.runtimeArgs(node, c);
    const param_offset: usize = if (target.mode == .none) 0 else 1;
    try emitCallArguments(self, node, target.key, r_args, param_offset, &args_buf);
    const zig_fn = try self.fnName(target.key);
    if (args_buf.items.len == 0) {
        return try std.fmt.allocPrint(a, "(try {s}(ctx))", .{zig_fn});
    }
    return try std.fmt.allocPrint(a, "(try {s}(ctx, {s}))", .{ zig_fn, try std.mem.join(a, ", ", args_buf.items) });
}

pub fn emitComparison(self: *Emitter, node: *ast_mod.Node, b: *const ast_mod.Binary) ![]const u8 {
    const a = self.arena.allocator();
    const op = b.operator;
    if (self.state.type_eq_folds.get(b.left)) |same| {
        return if (same) "true" else "false";
    }
    const lt = try self.valueType(b.left);
    const rt = try self.valueType(b.right);
    const eq = std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=");
    if (lt.may_error or rt.may_error) {
        if (eq and lt.kind == .error_value and rt.kind == .error_value) {
            const base = try std.fmt.allocPrint(a, "rt.err.eq({s}, {s})", .{
                try errorOperandCode(self, b.left), try errorOperandCode(self, b.right),
            });
            return if (std.mem.eql(u8, op, "!=")) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        return self.failAt(node, "error-union operand must be handled with '?' first", .{});
    }

    if (eq) {
        const negate = std.mem.eql(u8, op, "!=");
        const lt_optional = lt.kind == .optional;
        const rt_optional = rt.kind == .optional;
        const lt_null = lt.kind == .null_value;
        const rt_null = rt.kind == .null_value;
        if ((lt_optional and rt_null) or (lt_null and rt_optional)) {
            const optional = if (lt_optional) b.left else b.right;
            return std.fmt.allocPrint(a, "({s} {s} null)", .{
                try emitExpr(self, optional),
                if (negate) "!=" else "==",
            });
        }
        if (lt_optional and rt_optional and std.mem.eql(u8, lt.zig, rt.zig)) {
            const base = try std.fmt.allocPrint(a, "({s} == {s})", .{
                try emitExpr(self, b.left), try emitExpr(self, b.right),
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt_null and rt_null) return if (negate) "false" else "true";
        if (lt.isByteSequence() and rt.isByteSequence()) {
            const l_expr = try emitExpr(self, b.left);
            const r_expr = try emitExpr(self, b.right);
            const left_slice = if (lt.kind == .array) try std.fmt.allocPrint(a, "({s})[0..]", .{l_expr}) else l_expr;
            const right_slice = if (rt.kind == .array) try std.fmt.allocPrint(a, "({s})[0..]", .{r_expr}) else r_expr;
            const base = try std.fmt.allocPrint(a, "rt.arith.eqStr({s}, {s})", .{
                left_slice, right_slice,
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt.kind == .bool and rt.kind == .bool) {
            const base = try std.fmt.allocPrint(a, "rt.arith.eqBool({s}, {s})", .{
                try emitExpr(self, b.left), try emitExpr(self, b.right),
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt.kind == .int and rt.kind == .int) {
            const base = try std.fmt.allocPrint(a, "rt.arith.eqI64({s}, {s})", .{
                try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
            });
            return if (negate) std.fmt.allocPrint(a, "(!{s})", .{base}) else base;
        }
        if (lt.kind == .float and rt.kind == .float) {
            const l = try emitF64Operand(self, b.left);
            const r = try emitF64Operand(self, b.right);
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
            fn_name, try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
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
        const l = if (use_f32) try emitF32Operand(self, b.left) else try emitF64Operand(self, b.left);
        const r = if (use_f32) try emitF32Operand(self, b.right) else try emitF64Operand(self, b.right);
        return std.fmt.allocPrint(a, "rt.arith.{s}({s}, {s})", .{ fn_name, l, r });
    }
    return self.failAt(node, "cannot order '{s}' and '{s}'", .{ lt.display, rt.display });
}

pub fn emitExpr(self: *Emitter, node: *ast_mod.Node) anyerror![]const u8 {
    switch (node.*) {
        .literal => |lit| return emitLiteral(self, node, lit),
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) {
                return self.failAt(node, "native backend (Phase 2) does not support '{s}' operands", .{@tagName(p.kind)});
            }
            const resolved = try self.lookupBinding(node, p.name);
            if (resolved.ir_type) |bind_ir| {
                const bind_peeled = ir.peelDefined(bind_ir);
                if (bind_peeled == .union_) {
                    if (self.recordedType(node)) |rec_t| {
                        const rec_peeled = ir.peelDefined(rec_t);
                        if (rec_peeled != .union_) {
                            const uinfo = try self.ensureUnionType(node, resolved.display);
                            for (uinfo.variants) |v| {
                                if (ir.typeEquals(rec_peeled, ir.peelDefined(v.arm_ir)) or ir.isSubtype(rec_peeled, v.arm_ir)) {
                                    return std.fmt.allocPrint(self.arena.allocator(), "({s}.{s})", .{ resolved.zig_name, v.zig_name });
                                }
                            }
                        }
                    }
                }
            }
            return resolved.zig_name;
        },
        .binary => |b| return emitBinary(self, node, &b),
        .unary => |u| return emitUnary(self, node, &u),
        .call => |c| return emitCall(self, node, &c),
        .member => |m| return emitMember(self, node, &m),
        .index => |ix| return emitIndex(self, node, &ix),
        .array_literal => |al| {
            const vt = try self.valueType(node);
            if (vt.kind == .struct_) {
                return emitTupleLiteral(self, node, &al, vt);
            }
            return emitArrayLiteral(self, node, &al, vt);
        },
        .struct_init => |si| return emitStructLiteral(self, node, &si, try self.valueType(node)),
        .unwrap_expr => |u| return emitOptionalUnwrap(self, node, &u),
        .comptime_expr => |ce| return emitExpr(self, ce.expr),
        .try_expr => |t| return emitTryExpr(self, node, &t),
        .error_expr => |e| return emitErrorExpr(self, node, &e),
        .if_expr => |i| return stmt_mod.emitIfValue(self, node, &i),
        .switch_expr => |sw| return stmt_mod.emitSwitchValue(self, node, &sw),
        .block => |b| return stmt_mod.emitBlockValue(self, node, &b),
        .declaration, .return_expr, .for_expr, .break_expr, .continue_expr, .defer_stmt, .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {
            return self.failAt(node, "native backend (Phase 2) does not support {s} in expression position", .{@tagName(node.*)});
        },
        else => {
            return self.failAt(node, "native backend (Phase 2) does not support {s} yet", .{@tagName(node.*)});
        },
    }
}

pub fn writeErrorReturn(self: *Emitter, node: *ast_mod.Node, err_code: []const u8) !void {
    if (self.cur_ret.kind == .error_value) {
        try self.writeIndent();
        try self.writer.print("return {s};\n", .{err_code});
        return;
    }
    if (self.cur_ret.may_error) {
        try self.writeIndent();
        try self.writer.print("return .{{ .err = {s} }};\n", .{err_code});
        return;
    }
    if (self.cur_ret.kind == .void) {
        try self.writeIndent();
        try self.writer.print("return rt.io.failMsg({s}.message);\n", .{err_code});
        return;
    }
    return self.failAt(node, "cannot propagate an error from a function returning '{s}'", .{self.cur_ret.display});
}

pub fn emitTryExpr(self: *Emitter, node: *ast_mod.Node, t: *const ast_mod.TryExpr) ![]const u8 {
    const a = self.arena.allocator();
    const vt = try self.valueType(t.expression);
    self.counter += 1;
    const id = self.counter;
    const tmp = try std.fmt.allocPrint(a, "lls_try_{d}", .{id});
    const value = try std.fmt.allocPrint(a, "lls_try_val_{d}", .{id});
    const err_name = try std.fmt.allocPrint(a, "lls_try_err_{d}", .{id});

    var buf: std.ArrayList(u8) = .empty;
    const old_writer = self.writer;
    const old_indent = self.indent;
    self.writer = buf.writer(a).any();
    self.indent += 1;
    defer {
        self.writer = old_writer;
        self.indent = old_indent;
    }

    try buf.appendSlice(a, "blk: {\n");
    try self.writeIndent();
    if (vt.kind == .error_value) {
        try self.writer.print("const {s}: rt.err.Error = {s};\n", .{ tmp, try emitExpr(self, t.expression) });
        try self.emitErrorCleanup();
        try writeErrorReturn(self, node, tmp);
    } else if (vt.may_error) {
        try self.writer.print("const {s}: {s} = {s};\n", .{ tmp, vt.zig, try emitExpr(self, t.expression) });
        try self.writeIndent();
        try self.writer.print("break :blk switch ({s}) {{\n", .{tmp});
        self.indent += 1;
        try self.writeIndent();
        try self.writer.print(".ok => |{s}| {s},\n", .{ value, value });
        try self.writeIndent();
        try self.writer.print(".err => |{s}| {{\n", .{err_name});
        self.indent += 1;
        try self.emitErrorCleanup();
        try writeErrorReturn(self, node, err_name);
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("},\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("};\n");
    } else {
        return self.failAt(node, "'?' requires an error or error-union value", .{});
    }
    try self.writer.writeAll("}");
    return buf.items;
}

pub fn emitErrorExpr(self: *Emitter, node: *ast_mod.Node, e: *const ast_mod.ErrorExpr) ![]const u8 {
    const a = self.arena.allocator();
    if (e.args.len != 1) {
        return self.failAt(node, "error() takes exactly 1 argument (a message string)", .{});
    }
    const message = try emitExpr(self, e.args[0]);
    return std.fmt.allocPrint(a, "rt.err.make({s})", .{message});
}

pub fn emitF32Operand(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const t = try self.valueType(node);
    if (t.may_error) return self.failAt(node, "error-union value must be handled with '?' first", .{});
    const code = try emitExpr(self, node);
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
    const code = try emitExpr(self, node);
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
    const l = if (use_f32) try emitF32Operand(self, b.left) else try emitF64Operand(self, b.left);
    const r = if (use_f32) try emitF32Operand(self, b.right) else try emitF64Operand(self, b.right);
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
    if (t.kind == .bool) {
        return std.fmt.allocPrint(a, "@as(i64, @intFromBool({s}))", .{try emitExpr(self, node)});
    }
    if (t.kind != .int) return self.failAt(node, "expected an integer operand, got '{s}'", .{t.display});
    const code = try emitExpr(self, node);
    if (t.isU64()) return std.fmt.allocPrint(a, "@as(i64, @bitCast({s}))", .{code});
    return code;
}

pub fn isBitwiseOp(op: []const u8) bool {
    return std.mem.eql(u8, op, "&") or std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "~");
}

pub fn isShiftOp(op: []const u8) bool {
    return std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>");
}

/// Map a bitwise compound assignment operator to its binary form (`&=` → `&`).
pub fn compoundBitwiseOp(op: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, op, "&=")) return "&";
    if (std.mem.eql(u8, op, "|=")) return "|";
    if (std.mem.eql(u8, op, "~=")) return "~";
    if (std.mem.eql(u8, op, "<<=")) return "<<";
    if (std.mem.eql(u8, op, ">>=")) return ">>";
    return null;
}

/// Lower `lhs op= rhs` for bitwise/shift compounds into a value expression
/// typed as `vt` (the destination's storage type).
pub fn emitCompoundBitwiseValue(
    self: *Emitter,
    left: *ast_mod.Node,
    right: *ast_mod.Node,
    bin_op: []const u8,
    vt: ValType,
) ![]const u8 {
    const a = self.arena.allocator();
    if (vt.kind != .int) {
        return self.failAt(left, "bitwise '{s}=' requires an integer destination, got '{s}'", .{ bin_op, vt.display });
    }
    const l = try emitI64Operand(self, left);
    const r = try emitI64Operand(self, right);
    const call = if (std.mem.eql(u8, bin_op, "&"))
        try std.fmt.allocPrint(a, "(rt.arith.band({s}, {s}))", .{ l, r })
    else if (std.mem.eql(u8, bin_op, "|"))
        try std.fmt.allocPrint(a, "(rt.arith.bor({s}, {s}))", .{ l, r })
    else if (std.mem.eql(u8, bin_op, "~"))
        try std.fmt.allocPrint(a, "(rt.arith.bxor({s}, {s}))", .{ l, r })
    else if (std.mem.eql(u8, bin_op, "<<"))
        try std.fmt.allocPrint(a, "(try rt.arith.shl({s}, {s}))", .{ l, r })
    else if (std.mem.eql(u8, bin_op, ">>"))
        try std.fmt.allocPrint(a, "(try rt.arith.shr({s}, {s}))", .{ l, r })
    else
        return self.failAt(left, "native backend does not support compound '{s}='", .{bin_op});
    if (isShiftOp(bin_op)) {
        const w = vt.width orelse return self.failAt(left, "missing integer width for '{s}='", .{bin_op});
        const cw = w.concrete();
        if (cw == .i64 or cw == .u64) return wrapWidth(self, vt, call);
        return std.fmt.allocPrint(a, "@as({s}, @intCast(try rt.arith.narrow(.{s}, {s})))", .{
            vt.zig, @tagName(cw), call,
        });
    }
    return wrapWidth(self, vt, call);
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
        if (self.state.proven_arithmetic.contains(node)) {
            plain_call = try std.fmt.allocPrint(a, "(rt.arith.{s}Proven(.{s}, {s}, {s}))", .{
                base, @tagName(w), try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
            });
        } else if (!wrap_needed) {
            plain_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}({s}, {s}))", .{
                base, try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
            });
        } else {
            checked_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}Checked(.{s}, {s}, {s}))", .{
                base, @tagName(w), try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
            });
        }
    } else if (std.mem.eql(u8, op, "+%") or std.mem.eql(u8, op, "-%") or std.mem.eql(u8, op, "*%")) {
        const base = switch (op[0]) {
            '+' => "add",
            '-' => "sub",
            else => "mul",
        };
        plain_call = try std.fmt.allocPrint(a, "(rt.arith.{s}Wrapped(.{s}, {s}, {s}))", .{
            base, @tagName(w), try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
        });
    } else if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
        const base = if (std.mem.eql(u8, op, "/")) "div" else "rem";
        plain_call = try std.fmt.allocPrint(a, "(try rt.arith.{s}({s}, {s}))", .{
            base, try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
        });
    } else if (std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "**")) {
        plain_call = try std.fmt.allocPrint(a, "(rt.arith.pow({s}, {s}))", .{
            try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
        });
    } else if (std.mem.eql(u8, op, "&") or std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "~")) {
        const base = switch (op[0]) {
            '&' => "band",
            '|' => "bor",
            else => "bxor",
        };
        plain_call = try std.fmt.allocPrint(a, "(rt.arith.{s}({s}, {s}))", .{
            base, try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
        });
    } else if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) {
        const base = if (std.mem.eql(u8, op, "<<")) "shl" else "shr";
        const call = try std.fmt.allocPrint(a, "(try rt.arith.{s}({s}, {s}))", .{
            base, try emitI64Operand(self, b.left), try emitI64Operand(self, b.right),
        });
        // The runtime computes in i64; keep the expression at its declared
        // width and range-check narrow results like checked arithmetic. u64
        // keeps the full bit pattern via the bitcast in `wrapWidth`.
        const cw = w.concrete();
        plain_call = if (cw == .i64 or cw == .u64)
            call
        else
            try std.fmt.allocPrint(a, "(try rt.arith.narrow(.{s}, {s}))", .{ @tagName(cw), call });
    } else {
        return self.failAt(node, "native backend (Phase 2) does not support operator '{s}'", .{op});
    }

    const call = checked_call orelse plain_call.?;
    return wrapWidth(self, lt, call);
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
        const code = try emitExpr(self, node);
        if (target.kind == .int and isIntLiteral(node)) {
            return std.fmt.allocPrint(a, "@as({s}, {s})", .{ target.zig, code });
        }
        if (target.kind == .float and isNumericLiteral(node)) {
            return std.fmt.allocPrint(a, "@as({s}, {s})", .{ target.zig, code });
        }
        // String literals are already string-compatible in Zig (print
        // accepts pointer-to-array, annotated slots coerce to []const u8).
    }
    return emitValueCoercedForce(self, node, target);
}

pub fn addrOfPointerCode(self: *Emitter, node: *ast_mod.Node, arg: *ast_mod.Node) ![]const u8 {
    const at = try self.valueType(arg);
    if (at.kind == .pointer) return emitExpr(self, arg);
    return emitAddressOf(self, node, arg);
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
            const place = stmt_mod.emitPlaceLvalue(self, arg) catch |err| {
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
    if (std.mem.eql(u8, u.operator, "const")) return emitExpr(self, u.arg);
    if (std.mem.eql(u8, u.operator, "&")) {
        return emitAddressOf(self, node, u.arg);
    }
    const t = try self.valueType(u.arg);
    if (t.may_error) {
        return self.failAt(u.arg, "error-union value must be handled with '?' first", .{});
    }
    if (std.mem.eql(u8, u.operator, "!")) {
        if (t.kind != .bool) {
            return self.failAt(node, "'!' requires a boolean operand, got '{s}'", .{t.display});
        }
        return std.fmt.allocPrint(a, "(!{s})", .{try emitExpr(self, u.arg)});
    }
    if (std.mem.eql(u8, u.operator, "-")) {
        if (t.kind == .float) {
            const fn_name = if (std.mem.eql(u8, t.zig, "f32")) "negF32" else "negF64";
            return std.fmt.allocPrint(a, "(rt.arith.{s}({s}))", .{ fn_name, try emitExpr(self, u.arg) });
        }
        if (t.kind != .int) {
            return self.failAt(node, "unary '-' requires a numeric operand", .{});
        }
        if (t.isI64()) {
            return std.fmt.allocPrint(a, "(try rt.arith.neg({s}))", .{try emitExpr(self, u.arg)});
        }
        const inner = try std.fmt.allocPrint(a, "(try rt.arith.neg({s}))", .{try emitI64Operand(self, u.arg)});
        return wrapWidth(self, t, inner);
    }
    if (std.mem.eql(u8, u.operator, "~")) {
        if (t.kind != .int) {
            return self.failAt(node, "unary '~' requires an integer operand", .{});
        }
        if (t.isI64()) {
            return std.fmt.allocPrint(a, "(rt.arith.bnot({s}))", .{try emitExpr(self, u.arg)});
        }
        const inner = try std.fmt.allocPrint(a, "(rt.arith.bnot({s}))", .{try emitI64Operand(self, u.arg)});
        return wrapWidth(self, t, inner);
    }
    return self.failAt(node, "native backend does not support unary '{s}'", .{u.operator});
}

pub fn emitValueCoerced(self: *Emitter, node: *ast_mod.Node, target: ValType) ![]const u8 {
    return emitValueCoercedMode(self, node, target, false);
}

pub fn emitValueCoercedForce(self: *Emitter, node: *ast_mod.Node, target: ValType) ![]const u8 {
    return emitValueCoercedMode(self, node, target, true);
}

pub fn emitValueCoercedMode(self: *Emitter, node: *ast_mod.Node, target: ValType, force: bool) ![]const u8 {
    const a = self.arena.allocator();
    const src = try self.valueType(node);
    if (target.kind == .error_value) {
        if (src.kind != .error_value) {
            return self.failAt(node, "cannot assign '{s}' to '{s}' in native emission", .{ src.display, target.display });
        }
        return emitExpr(self, node);
    }
    if (target.may_error) {
        if (src.kind == .error_value) {
            return std.fmt.allocPrint(a, ".{{ .err = {s} }}", .{try emitExpr(self, node)});
        }
        if (src.may_error) {
            if (std.mem.eql(u8, src.zig, target.zig)) return emitExpr(self, node);
            return self.failAt(node, "cannot assign error union '{s}' to '{s}' in native emission", .{ src.display, target.display });
        }
        const success = target.success orelse {
            return self.failAt(node, "native backend cannot determine the success type of '{s}'", .{target.display});
        };
        const inner = try emitValueCoercedMode(self, node, success.*, force);
        return std.fmt.allocPrint(a, ".{{ .ok = {s} }}", .{inner});
    }
    if (src.may_error) {
        return self.failAt(node, "error-union value must be handled with '?' first", .{});
    }
    if (target.kind == .union_) {
        if (src.kind == .union_ and std.mem.eql(u8, src.zig, target.zig)) {
            return emitExpr(self, node);
        }
        const uinfo = try self.ensureUnionType(node, target.display);
        for (uinfo.variants) |v| {
            if (std.mem.eql(u8, src.zig, v.vt.zig) or std.mem.eql(u8, src.clean, v.vt.clean) or std.mem.eql(u8, src.display, v.vt.display)) {
                const inner = try emitValueCoercedMode(self, node, v.vt, force);
                return std.fmt.allocPrint(a, "{s}{{ .{s} = {s} }}", .{ target.zig, v.zig_name, inner });
            }
        }
        if (self.recordedType(node)) |src_ir| {
            for (uinfo.variants) |v| {
                if (ir.isSubtype(src_ir, v.arm_ir)) {
                    const inner = try emitValueCoercedMode(self, node, v.vt, force);
                    return std.fmt.allocPrint(a, "{s}{{ .{s} = {s} }}", .{ target.zig, v.zig_name, inner });
                }
            }
        }
        return self.failAt(node, "cannot coerce '{s}' to union '{s}'", .{ src.display, target.display });
    }
    if (node.* == .array_literal and target.kind == .array) {
        return emitArrayLiteral(self, node, &node.array_literal, target);
    }
    if (node.* == .array_literal and target.kind == .struct_) {
        return emitTupleLiteral(self, node, &node.array_literal, target);
    }
    // `@as(string, [104, 105])` / `@as([]byte, […])` — integer-literal arrays
    // become a fresh byte slice (same path as slice literals).
    if (node.* == .array_literal and (target.kind == .slice or target.kind == .string)) {
        return emitSliceLiteral(self, node, &node.array_literal, target);
    }
    if (node.* == .struct_init and target.kind == .struct_) {
        return emitStructLiteral(self, node, &node.struct_init, target);
    }
    const code = try emitExpr(self, node);

    // Literals are already polymorphic; the surrounding declaration,
    // assignment, return, print, or @as supplies the concrete type.
    if (node.* == .literal and !isNullLiteral(node)) {
        if (target.kind == .array and node.literal.literal_type == .string) {
            return std.fmt.allocPrint(a, "{s}.*", .{code});
        }
        if (target.kind == .slice and !target.is_const and target.elem != null and std.mem.eql(u8, target.elem.?.zig, "u8") and node.literal.literal_type == .string) {
            return std.fmt.allocPrint(a, "(try rt.mem.cloneBytes(ctx, {s}))", .{code});
        }
        return code;
    }

    if (src.kind == .slice and target.kind == .slice and
        (node.* == .primary or node.* == .member))
    {
        return emitCloneSlice(self, node, src, code);
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
        return emitArrayToSlice(self, node, src, target, code);
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
    if (target.kind == .int and src.kind == .float) {
        return std.fmt.allocPrint(a, "@as({s}, @intFromFloat({s}))", .{ target.zig, code });
    }
    if (target.kind == .void and src.kind == .void) return code;
    if (target.kind == .bool and src.kind == .bool) return code;
    if (target.kind == .bool and src.kind == .int) {
        return std.fmt.allocPrint(a, "({s} != 0)", .{code});
    }
    if (target.kind == .string and src.kind == .string) return code;
    if (target.kind == .string and isByteSliceType(src)) return code;
    if (isByteSliceType(target) and isByteSliceType(src)) {
        if (target.kind == .slice and !target.is_const and src.kind == .string) {
            return std.fmt.allocPrint(a, "(try rt.mem.cloneBytes(ctx, {s}))", .{code});
        }
        return code;
    }
    if (target.kind == .struct_ and src.kind == .struct_) return code;
    // `return self` from a pointer-receiver method: the VM reports the struct
    // display, so native copies the pointee to match the declared type.
    if (target.kind == .struct_ and src.kind == .pointer and src.payload != null and
        src.payload.?.kind == .struct_ and std.mem.eql(u8, src.payload.?.zig, target.zig))
    {
        return std.fmt.allocPrint(a, "({s}).*", .{code});
    }
    // Explicit `@as(T, ptr)` only (`force`): load the pointee. Never auto-deref
    // on ordinary assign/argument conversion — that would hide the load.
    if (force and src.kind == .pointer) {
        if (src.payload) |p| {
            if (pointerPointeeMatches(p.*, target)) {
                return std.fmt.allocPrint(a, "({s}).*", .{code});
            }
        }
    }
    if (target.kind == .array and src.kind == .array) return code;
    if (target.kind == .slice and src.kind == .slice) return code;
    if (target.kind == .pointer and src.kind == .pointer) return code;
    return self.failAt(node, "cannot assign '{s}' to '{s}' in native emission", .{ src.display, target.display });
}

fn pointerPointeeMatches(pointee: ValType, target: ValType) bool {
    if (pointee.kind == target.kind and std.mem.eql(u8, pointee.zig, target.zig)) return true;
    // string ≡ []byte ≡ []const u8 at the ValType layer.
    if (pointee.kind == .string and target.kind == .string) return true;
    if (pointee.kind == .slice and target.kind == .slice) {
        if (pointee.elem == null or target.elem == null) return false;
        return std.mem.eql(u8, pointee.elem.?.zig, target.elem.?.zig);
    }
    return false;
}

pub fn isNullLiteral(node: *ast_mod.Node) bool {
    if (node.* != .literal) return false;
    return node.literal.literal_type == .null;
}

pub fn containsStruct(t: ValType) bool {
    if (t.may_error) {
        if (t.success) |success| return containsStruct(success.*);
    }
    return switch (t.kind) {
        .struct_ => true,
        .array, .slice => if (t.elem) |e| containsStruct(e.*) else false,
        .optional, .pointer => if (t.payload) |p| containsStruct(p.*) else false,
        else => false,
    };
}

pub fn resolveMemberField(self: *Emitter, node: *ast_mod.Node, m: *const ast_mod.Member) !?MemberTarget {
    if (m.property.* != .primary) return null;
    if (m.object.* == .primary and self.state.error_sets.contains(m.object.primary.name)) return null;
    const field_name = m.property.primary.name;
    const obj_t = try self.valueType(m.object);
    const info = (try self.structInfoForValType(m.object, obj_t)) orelse return null;
    const index = info.field_index.get(field_name) orelse {
        return self.failAt(m.property, "native backend cannot resolve field '{s}'", .{field_name});
    };
    _ = node;
    return .{ .info = info, .index = index };
}

pub fn errorOperandCode(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
    const t = try self.storageValueType(node);
    const code = try emitExpr(self, node);
    if (t.may_error and t.kind != .error_value) {
        return std.fmt.allocPrint(self.arena.allocator(), "rt.err.expectError({s})", .{code});
    }
    return code;
}

pub fn emitMemberAccess(self: *Emitter, node: *ast_mod.Node, m: *const ast_mod.Member) ![]const u8 {
    const target = (try resolveMemberField(self, node, m)) orelse {
        return self.failAt(node, "native backend cannot lower member access '.{s}' yet", .{
            if (m.property.* == .primary) m.property.primary.name else "?",
        });
    };
    const obj_t = try self.valueType(m.object);
    const field = target.info.fields[target.index];
    const deref: []const u8 = if (obj_t.kind == .pointer) ".*" else "";
    return std.fmt.allocPrint(self.arena.allocator(), "({s}){s}.{s}", .{
        try emitExpr(self, m.object), deref, field.zig_name,
    });
}

pub fn emitMember(self: *Emitter, node: *ast_mod.Node, m: *const ast_mod.Member) ![]const u8 {
    const a = self.arena.allocator();
    if (m.object.* == .primary and m.property.* == .primary) {
        const object_name = m.object.primary.name;
        const member_name = m.property.primary.name;
        if (self.state.enums.get(object_name)) |ed| {
            const variant = member_name;
            if (ed.string_values) |values| {
                if (values.get(variant)) |s| return self.zigString(s);
            }
            const value = ed.variants.get(variant) orelse {
                return self.failAt(node, "native backend cannot resolve enum variant '{s}'", .{variant});
            };
            return std.fmt.allocPrint(a, "{d}", .{value});
        }
        if (self.state.error_sets.get(object_name)) |ed| {
            if (ed.variants.contains(member_name)) {
                return std.fmt.allocPrint(a, "rt.err.make({s})", .{try self.zigString(member_name)});
            }
            return self.failAt(node, "native backend cannot resolve error member '{s}'", .{member_name});
        }
    }
    if (m.property.* == .primary) {
        // `mod.CONST` / `mod.sub.CONST`: module globals are emitted under their
        // qualified `module::NAME` keys, so read the emitted binding directly.
        if ((path_mod.tryResolveStaticPath(self.state, node) catch null)) |import_key| {
            if (self.globals.get(import_key)) |g| return g.zig_name;
        }
        const obj_t = try self.storageValueType(m.object);
        if (obj_t.kind == .error_value or obj_t.may_error) {
            const prop = m.property.primary.name;
            const object_code = try emitExpr(self, m.object);
            const err_code = if (obj_t.kind == .error_value)
                object_code
            else
                try std.fmt.allocPrint(a, "rt.err.expectError({s})", .{object_code});
            if (std.mem.eql(u8, prop, "message")) {
                return std.fmt.allocPrint(a, "({s}).message", .{err_code});
            }
        }
        if (obj_t.kind == .union_) {
            const prop = m.property.primary.name;
            const uinfo = try self.ensureUnionType(m.object, obj_t.display);
            if (uinfo.discrim_field) |df| {
                if (std.mem.eql(u8, prop, df)) {
                    const object_code = try emitExpr(self, m.object);
                    return std.fmt.allocPrint(a, "({s}).get_{s}()", .{ object_code, df });
                }
            }
        }
    }
    return emitMemberAccess(self, node, m);
}

pub fn emitIndex(self: *Emitter, node: *ast_mod.Node, ix: *const ast_mod.Index) ![]const u8 {
    if (ix.is_slice) return emitSlice(self, node, ix);

    const a = self.arena.allocator();
    var obj_t = try self.valueType(ix.object);
    var object_expr = try emitExpr(self, ix.object);
    if (obj_t.kind == .pointer) {
        const payload = obj_t.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{obj_t.display});
        obj_t = payload.*;
        object_expr = try std.fmt.allocPrint(a, "({s}).*", .{object_expr});
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
                        return std.fmt.allocPrint(a, "({s}).{s}", .{ object_expr, field.zig_name });
                    }
                }
            }
        }
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
    const index_code = try emitI64Operand(self, index_node);

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
        obj_name, obj_t.zig,  object_expr,
        idx_name, index_code, idx_name,
        idx_name, obj_name,   try self.zigString(fmt),
        idx_name, obj_name,   obj_name,
        idx_name,
    });
}

pub fn emitSlice(self: *Emitter, node: *ast_mod.Node, ix: *const ast_mod.Index) ![]const u8 {
    const a = self.arena.allocator();
    var obj_t = try self.valueType(ix.object);
    var object_expr = try emitExpr(self, ix.object);
    if (obj_t.kind == .pointer) {
        const payload = obj_t.payload orelse return self.failAt(node, "native backend cannot determine the pointee type of '{s}'", .{obj_t.display});
        obj_t = payload.*;
        object_expr = try std.fmt.allocPrint(a, "({s}).*", .{object_expr});
    }
    if (obj_t.kind != .string and obj_t.kind != .slice and obj_t.kind != .array) {
        return self.failAt(node, "native backend cannot slice '{s}' yet", .{obj_t.display});
    }
    self.counter += 1;
    const id = self.counter;
    const obj_name = try std.fmt.allocPrint(a, "lls_slice_obj_{d}", .{id});
    const lo_name = try std.fmt.allocPrint(a, "lls_slice_lo_{d}", .{id});
    const hi_name = try std.fmt.allocPrint(a, "lls_slice_hi_{d}", .{id});

    const lo_code = if (ix.index) |idx| try emitI64Operand(self, idx) else "0";
    const hi_code = if (ix.end) |end|
        try emitI64Operand(self, end)
    else
        try std.fmt.allocPrint(a, "@as(i64, @intCast({s}.len))", .{obj_name});

    // Slicing a local array value keeps the source mutability: `const arr`
    // yields `*const [N]T` (a read-only view), while a mutable array must stay
    // mutable so the resulting `[]T` is writable.
    const obj_decl: []const u8 = if (obj_t.kind == .array and !obj_t.is_const) "var" else "const";

    return std.fmt.allocPrint(a,
        \\blk: {{
        \\    {s} {s}: {s} = {s};
        \\    const {s}: i64 = {s};
        \\    const {s}: i64 = {s};
        \\    if ({s} < 0 or {s} < {s} or {s} > @as(i64, @intCast({s}.len))) return rt.io.fail("Slice out of bounds: [{{d}}..{{d}}] (len {{d}})", .{{ {s}, {s}, @as(i64, @intCast({s}.len)) }});
        \\    break :blk {s}[@intCast({s})..@intCast({s})];
        \\}}
    , .{
        obj_decl, obj_name, obj_t.zig, object_expr,
        lo_name,  lo_code,  hi_name,   hi_code,
        lo_name,  hi_name,  lo_name,   hi_name,
        obj_name, lo_name,  hi_name,   obj_name,
        obj_name, lo_name,  hi_name,
    });
}

pub fn emitTupleLiteral(self: *Emitter, node: *ast_mod.Node, al: *const ast_mod.ArrayLiteral, target: ValType) ![]const u8 {
    const a = self.arena.allocator();
    const info = (try self.structInfoForValType(node, target)) orelse {
        return self.failAt(node, "native backend cannot determine tuple layout for '{s}'", .{target.display});
    };
    if (al.elements.len != info.fields.len) {
        return self.failAt(node, "tuple literal element count ({d}) does not match expected ({d})", .{ al.elements.len, info.fields.len });
    }
    var parts: std.ArrayList([]const u8) = .empty;
    for (al.elements, info.fields) |element, field| {
        const val_code = try emitValueCoerced(self, element, field.vt);
        try parts.append(a, try std.fmt.allocPrint(a, ".{s} = {s}", .{ field.zig_name, val_code }));
    }
    const joined = try std.mem.join(a, ", ", parts.items);
    return std.fmt.allocPrint(a, "{s}{{ {s} }}", .{ target.zig, joined });
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
        try parts.append(a, try emitValueCoerced(self, element, elem.*));
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
        src_name,  src.zig,  src_code,
        buf_name,  src_name, elem.zig,
        elem.zig,  dst_name, elem.zig,
        buf_name,  src_name, item_name,
        i_name,    dst_name, i_name,
        item_name, dst_name, src_name,
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
        src_name, src.zig,  src_code,
        buf_name, len,      elem.zig,
        elem.zig, dst_name, len,
        elem.zig, buf_name, dst_name,
        src_name, dst_name, len,
    });
}

pub fn emitSliceLiteral(self: *Emitter, node: *ast_mod.Node, al: *const ast_mod.ArrayLiteral, target: ValType) ![]const u8 {
    const a = self.arena.allocator();
    const elem = target.elem orelse {
        return self.failAt(node, "native backend cannot determine the slice element type", .{});
    };
    var parts: std.ArrayList([]const u8) = .empty;
    for (al.elements) |element| {
        try parts.append(a, try emitValueCoerced(self, element, elem.*));
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
            try emitValueCoerced(self, value, field.vt)
        else
            try unit_mod.zeroValue(self, field.vt);
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
    if (vt.kind != .optional) return emitExpr(self, u.expression);
    return std.fmt.allocPrint(self.arena.allocator(), "({s} orelse return rt.io.fail(\"Attempted to unwrap null\"))", .{
        try emitExpr(self, u.expression),
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

fn isByteSliceType(t: ValType) bool {
    if (t.kind == .string) return true;
    if (t.kind == .slice and t.elem != null and std.mem.eql(u8, t.elem.?.zig, "u8")) return true;
    return false;
}

pub fn isStringy(self: *Emitter, node: *ast_mod.Node) !bool {
    const t = try self.valueType(node);
    return t.kind == .string;
}

fn isStringBufferPtr(self: *Emitter, node: *ast_mod.Node) !bool {
    const t = try self.valueType(node);
    return t.kind == .pointer and t.payload != null and t.payload.?.kind == .string;
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

fn emitNameOfEnum(self: *Emitter, node: *ast_mod.Node, ename: []const u8, arg: *ast_mod.Node) ![]const u8 {
    const a = self.arena.allocator();
    const ed = self.state.enums.get(ename) orelse {
        return self.failAt(node, "native backend cannot resolve enum type '{s}' for @nameOf", .{ename});
    };

    const Entry = struct { name: []const u8, val: i32 };
    var variants: std.ArrayList(Entry) = .empty;
    defer variants.deinit(a);
    var it = ed.variants.iterator();
    while (it.next()) |e| {
        try variants.append(a, .{ .name = e.key_ptr.*, .val = e.value_ptr.* });
    }
    std.mem.sort(Entry, variants.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return x.val < y.val;
        }
    }.less);

    self.counter += 1;
    const id = self.counter;
    const arg_code = try emitExpr(self, arg);

    var out: std.ArrayList(u8) = .empty;
    const w = out.writer(a);
    if (ed.isString()) {
        const values = ed.string_values.?;
        try w.print("blk: {{ const lls_nameof_{d} = {s}; ", .{ id, arg_code });
        for (variants.items) |item| {
            const s = values.get(item.name) orelse continue;
            try w.print("if (rt.arith.eqStr(lls_nameof_{d}, {s})) break :blk {s}; ", .{
                id, try self.zigString(s), try self.zigString(item.name),
            });
        }
        try w.writeAll("break :blk \"\"; }");
        return out.toOwnedSlice(a);
    }

    try w.print("blk: {{ const lls_nameof_{d}: i64 = {s}; break :blk switch (lls_nameof_{d}) {{ ", .{
        id, arg_code, id,
    });
    var prev: ?i32 = null;
    for (variants.items) |item| {
        if (prev != null and prev.? == item.val) continue;
        prev = item.val;
        try w.print("{d} => {s}, ", .{ item.val, try self.zigString(item.name) });
    }
    try w.writeAll("else => \"\", }; }");
    return out.toOwnedSlice(a);
}

fn exprHasEffects(node: *ast_mod.Node) bool {
    return switch (node.*) {
        .call, .index, .try_expr, .unwrap_expr => true,
        .binary => |b| exprHasEffects(b.left) or exprHasEffects(b.right),
        .unary => |u| exprHasEffects(u.arg),
        .member => |m| exprHasEffects(m.object),
        .array_literal => |al| blk: {
            for (al.elements) |e| if (exprHasEffects(e)) break :blk true;
            break :blk false;
        },
        .struct_init => |si| blk: {
            for (si.fields) |f| if (exprHasEffects(f.value)) break :blk true;
            break :blk false;
        },
        .error_expr => |e| blk: {
            for (e.args) |arg| if (exprHasEffects(arg)) break :blk true;
            break :blk false;
        },
        .comptime_expr => |ce| exprHasEffects(ce.expr),
        else => false,
    };
}
