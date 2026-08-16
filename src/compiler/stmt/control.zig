const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const scope = @import("../scope.zig");
const state_mod = @import("../state.zig");
const expr = @import("../expr/root.zig");
const stmt = @import("root.zig");
const for_loop = @import("for_loop.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileIf(state: *CompilerState, if_expr: *const ast.If) !void {
    try expr.compileExpression(state, if_expr.condition);
    const then_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);
    try scope.beginScope(state);
    const body = switch (if_expr.body.*) {
        .block => |*b| b,
        else => return fail(state, "if body must be block"),
    };
    for (body.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);

    if (if_expr.else_body) |else_body| {
        const else_jump = try emit.emitJump(state, .OP_JUMP);
        emit.patchJump(state, then_jump);
        try emit.emitOp(state, .OP_POP);
        if (else_body.* == .block) {
            try scope.beginScope(state);
            for (else_body.block.statements) |s| try stmt.compileStatement(state, s);
            try scope.endScope(state);
        } else if (else_body.* == .if_expr) {
            try compileIf(state, &else_body.if_expr);
        }
        emit.patchJump(state, else_jump);
    } else {
        const skip_pop = try emit.emitJump(state, .OP_JUMP);
        emit.patchJump(state, then_jump);
        try emit.emitOp(state, .OP_POP);
        emit.patchJump(state, skip_pop);
    }
}

/// Value-producing `@if`: every arm must `break <value>`; result left on the stack.
pub fn compileIfValue(state: *CompilerState, if_expr: *const ast.If) !void {
    if (if_expr.else_body == null) return fail(state, "value-producing @if requires @else");
    try beginExprFrame(state, if_expr.label);
    try compileIfValueBody(state, if_expr);
    try finishExprFrame(state);
}

fn compileIfValueBody(state: *CompilerState, if_expr: *const ast.If) !void {
    try expr.compileExpression(state, if_expr.condition);
    const then_jump = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
    try emit.emitOp(state, .OP_POP);

    try compileValueArm(state, if_expr.body, "then");

    const end_jump = try emit.emitJump(state, .OP_JUMP);
    emit.patchJump(state, then_jump);
    try emit.emitOp(state, .OP_POP);

    const else_body = if_expr.else_body orelse return fail(state, "value-producing @if requires @else");
    if (else_body.* == .if_expr) {
        try compileIfValueBody(state, &else_body.if_expr);
    } else {
        try compileValueArm(state, else_body, "else");
    }
    emit.patchJump(state, end_jump);
}

pub fn compileSwitch(state: *CompilerState, sw: *const ast.Switch) !void {
    _ = try checkEnumExhaustiveness(state, sw);
    _ = try checkErrorExhaustiveness(state, sw);
    try compileSwitchInner(state, sw, false);
}

pub fn compileSwitchValue(state: *CompilerState, sw: *const ast.Switch) !void {
    const exhaustive = (try checkEnumExhaustiveness(state, sw)) or (try checkErrorExhaustiveness(state, sw));
    if (!hasElseProng(sw) and !exhaustive) {
        return fail(state, "value-producing @switch requires @else (or cover every enum/error variant)");
    }
    try beginExprFrame(state, sw.label);
    try compileSwitchInner(state, sw, true);
    try finishExprFrame(state);
}

fn hasElseProng(sw: *const ast.Switch) bool {
    for (sw.prongs) |p| {
        if (p.is_else) return true;
    }
    return false;
}

fn enumNameFromTypeDisplay(state: *CompilerState, display: []const u8) ?[]const u8 {
    if (state.enums.contains(display)) return display;
    // `ExprKind.Literal` → parent enum for exhaustiveness.
    if (std.mem.lastIndexOfScalar(u8, display, '.')) |dot| {
        const ename = display[0..dot];
        if (state.enums.contains(ename)) return ename;
    }
    return null;
}

/// Returns true when scrutinee is an enum and every variant is covered (or `@else` present).
fn checkEnumExhaustiveness(state: *CompilerState, sw: *const ast.Switch) !bool {
    if (hasElseProng(sw)) return true;
    const types = @import("../typecheck/from_ast.zig");

    // `@switch (e.kind)` on discrim union `Literal | Add` — cover union arms, not full enum.
    if (sw.condition.* == .member and sw.condition.member.property.* == .primary and
        std.mem.eql(u8, sw.condition.member.property.primary.name, "kind"))
    {
        if (types.resolveType(state, sw.condition.member.object)) |obj_disp| {
            if (try types.discrimVariantMap(state, state.allocator, obj_disp)) |info_owned| {
                var info = info_owned;
                defer info.map.deinit();
                var covered = std.StringHashMap(void).init(state.allocator);
                defer covered.deinit();
                for (sw.prongs) |prong| {
                    if (prong.is_else) continue;
                    for (prong.patterns) |pat| {
                        if (resolveEnumVariantPattern(state, pat, info.enum_name)) |vname| {
                            try covered.put(vname, {});
                        }
                    }
                }
                var missing: std.ArrayList([]const u8) = .empty;
                defer missing.deinit(state.allocator);
                var kit = info.map.keyIterator();
                while (kit.next()) |k| {
                    if (!covered.contains(k.*)) try missing.append(state.allocator, k.*);
                }
                if (missing.items.len == 0) return true;
                return failMissingVariants(state, missing.items);
            }
        }
    }

    const raw = types.resolveType(state, sw.condition) orelse return false;

    // Singleton `ExprKind.Literal` — only that variant must be covered.
    if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| {
        const ename = raw[0..dot];
        const vname = raw[dot + 1 ..];
        if (state.enums.get(ename)) |ed| {
            if (ed.variants.contains(vname)) {
                for (sw.prongs) |prong| {
                    if (prong.is_else) return true;
                    for (prong.patterns) |pat| {
                        if (resolveEnumVariantPattern(state, pat, ename)) |pv| {
                            if (std.mem.eql(u8, pv, vname)) return true;
                        }
                    }
                }
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "@switch is missing enum variant: {s}", .{vname}) catch "@switch is missing enum variant";
                return fail(state, msg);
            }
        }
    }

    const ename = enumNameFromTypeDisplay(state, raw) orelse return false;
    const ed = state.enums.get(ename) orelse return false;

    var covered = std.StringHashMap(void).init(state.allocator);
    defer covered.deinit();

    for (sw.prongs) |prong| {
        if (prong.is_else) continue;
        for (prong.patterns) |pat| {
            if (resolveEnumVariantPattern(state, pat, ename)) |vname| {
                try covered.put(vname, {});
            }
        }
    }

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(state.allocator);
    var vit = ed.variants.keyIterator();
    while (vit.next()) |k| {
        if (!covered.contains(k.*)) try missing.append(state.allocator, k.*);
    }
    if (missing.items.len == 0) return true;
    return failMissingVariants(state, missing.items);
}

fn failMissingVariants(state: *CompilerState, missing: []const []const u8) error{CompileError} {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("@switch is missing enum variant") catch {};
    if (missing.len > 1) w.writeAll("s") catch {};
    w.writeAll(": ") catch {};
    for (missing, 0..) |m, i| {
        if (i > 0) w.writeAll(", ") catch {};
        w.writeAll(m) catch {};
    }
    return fail(state, fbs.getWritten());
}

fn resolveEnumVariantPattern(state: *CompilerState, pat: *ast.Node, expected_enum: []const u8) ?[]const u8 {
    const types = @import("../typecheck/from_ast.zig");
    if (pat.* != .member) return null;
    const mem = &pat.member;
    if (mem.property.* != .primary) return null;
    const ename = types.resolveEnumName(state, mem.object) orelse return null;
    if (!std.mem.eql(u8, ename, expected_enum)) return null;
    const ed = state.enums.get(ename) orelse return null;
    if (!ed.variants.contains(mem.property.primary.name)) return null;
    return mem.property.primary.name;
}

/// Collect required error patterns as `"Origin.Member"` strings from a type display
/// (single set, `|` of sets, `&` merge name, or singleton lit).
fn collectErrorMembers(state: *CompilerState, display: []const u8, out: *std.StringHashMap(void)) !bool {
    const types = @import("../typecheck/from_ast.zig");
    const bare = types.peelTypedefDisplay(state, display);
    if (state.error_sets.get(bare)) |es| {
        var it = es.variants.iterator();
        while (it.next()) |e| {
            const origin = e.value_ptr.*;
            const member = e.key_ptr.*;
            const key = try std.fmt.allocPrint(state.allocator, "{s}.{s}", .{ origin, member });
            try state.owned.append(state.allocator, key);
            try out.put(key, {});
        }
        return true;
    }
    // Singleton `IoError.NotFound`
    if (std.mem.lastIndexOfScalar(u8, bare, '.')) |dot| {
        const esname = bare[0..dot];
        const vname = bare[dot + 1 ..];
        if (state.error_sets.get(esname)) |es| {
            if (es.variants.contains(vname)) {
                const key = try std.fmt.allocPrint(state.allocator, "{s}.{s}", .{ esname, vname });
                try state.owned.append(state.allocator, key);
                try out.put(key, {});
                return true;
            }
        }
    }
    if (std.mem.indexOf(u8, bare, " | ") == null) return false;
    const parts = types.splitUnionDisplay(state.allocator, bare) catch return false;
    defer state.allocator.free(parts);
    var any = false;
    for (parts) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (try collectErrorMembers(state, p, out)) any = true;
    }
    return any;
}

/// Strict exhaustiveness for closed error sets / unions / merges (or `@else`).
fn checkErrorExhaustiveness(state: *CompilerState, sw: *const ast.Switch) !bool {
    if (hasElseProng(sw)) return true;
    const types = @import("../typecheck/from_ast.zig");
    const raw = types.resolveType(state, sw.condition) orelse return false;

    var required = std.StringHashMap(void).init(state.allocator);
    defer required.deinit();
    if (!try collectErrorMembers(state, raw, &required)) return false;
    if (required.count() == 0) return false;

    var covered = std.StringHashMap(void).init(state.allocator);
    defer covered.deinit();
    for (sw.prongs) |prong| {
        if (prong.is_else) continue;
        for (prong.patterns) |pat| {
            if (resolveErrorMemberPattern(state, pat)) |key| {
                try covered.put(key, {});
            }
        }
    }

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(state.allocator);
    var rit = required.keyIterator();
    while (rit.next()) |k| {
        if (!covered.contains(k.*)) try missing.append(state.allocator, k.*);
    }
    if (missing.items.len == 0) return true;
    return failMissingErrorMembers(state, missing.items);
}

fn failMissingErrorMembers(state: *CompilerState, missing: []const []const u8) error{CompileError} {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("@switch is missing error member") catch {};
    if (missing.len > 1) w.writeAll("s") catch {};
    w.writeAll(": ") catch {};
    for (missing, 0..) |m, i| {
        if (i > 0) w.writeAll(", ") catch {};
        w.writeAll(m) catch {};
    }
    return fail(state, fbs.getWritten());
}

fn resolveErrorMemberPattern(state: *CompilerState, pat: *ast.Node) ?[]const u8 {
    const types = @import("../typecheck/from_ast.zig");
    if (pat.* != .member) return null;
    const mem = &pat.member;
    if (mem.property.* != .primary) return null;
    const esname = types.resolveErrorSetName(state, mem.object) orelse return null;
    const ed = state.error_sets.get(esname) orelse return null;
    if (!ed.variants.contains(mem.property.primary.name)) return null;
    // Prefer origin from the set def (merged sets map member → component origin).
    const origin = ed.variants.get(mem.property.primary.name) orelse esname;
    const key = std.fmt.allocPrint(state.allocator, "{s}.{s}", .{ origin, mem.property.primary.name }) catch return null;
    state.owned.append(state.allocator, key) catch {};
    return key;
}

fn compileSwitchInner(state: *CompilerState, sw: *const ast.Switch, value_mode: bool) !void {
    const types = @import("../typecheck/from_ast.zig");

    try scope.beginScope(state);
    try expr.compileExpression(state, sw.condition);
    const scrut_slot = try scope.addLocal(state, "", false);

    // Discrim narrowing: `@switch (e.kind)` on `e: A | B`.
    var narrow_subject: ?[]const u8 = null;
    var narrow_map: ?std.StringHashMap([]const u8) = null;
    var narrow_enum: ?[]const u8 = null;
    defer if (narrow_map) |*m| m.deinit();
    if (sw.condition.* == .member and sw.condition.member.property.* == .primary and
        std.mem.eql(u8, sw.condition.member.property.primary.name, "kind") and
        sw.condition.member.object.* == .primary)
    {
        const subject = sw.condition.member.object.primary.name;
        if (types.resolveType(state, sw.condition.member.object)) |disp| {
            if (try types.discrimVariantMap(state, state.allocator, disp)) |info| {
                narrow_subject = subject;
                narrow_map = info.map;
                narrow_enum = info.enum_name;
            }
        }
    }

    var covered = std.StringHashMap(void).init(state.allocator);
    defer covered.deinit();
    if (narrow_map) |map| {
        if (narrow_enum) |ename| {
            for (sw.prongs) |prong| {
                if (prong.is_else) continue;
                for (prong.patterns) |pat| {
                    if (resolveEnumVariantPattern(state, pat, ename)) |vname| {
                        if (map.contains(vname)) try covered.put(vname, {});
                    }
                }
            }
        }
    }

    var end_jumps: std.ArrayList(usize) = .empty;
    defer end_jumps.deinit(state.allocator);

    for (sw.prongs) |prong| {
        if (prong.is_else) {
            var saved_ty: ?[]const u8 = null;
            var local_i: i32 = -1;
            if (narrow_subject) |subj| {
                if (narrow_map) |map| {
                    var rem: std.ArrayList([]const u8) = .empty;
                    defer rem.deinit(state.allocator);
                    var it = map.iterator();
                    while (it.next()) |e| {
                        if (!covered.contains(e.key_ptr.*)) try rem.append(state.allocator, e.value_ptr.*);
                    }
                    if (rem.items.len == 1) {
                        local_i = scope.resolveLocal(state, subj);
                        if (local_i >= 0) {
                            saved_ty = state.locals.items[@intCast(local_i)].type_name;
                            state.locals.items[@intCast(local_i)].type_name = rem.items[0];
                        }
                    } else if (rem.items.len > 1) {
                        var parts: std.ArrayList([]const u8) = .empty;
                        defer parts.deinit(state.allocator);
                        for (rem.items) |s| try parts.append(state.allocator, s);
                        // "A | B | …"
                        var len: usize = 0;
                        for (parts.items, 0..) |p, i| {
                            len += p.len;
                            if (i > 0) len += 3;
                        }
                        const joined = try state.allocator.alloc(u8, len);
                        try state.owned.append(state.allocator, joined);
                        var off: usize = 0;
                        for (parts.items, 0..) |p, i| {
                            if (i > 0) {
                                @memcpy(joined[off .. off + 3], " | ");
                                off += 3;
                            }
                            @memcpy(joined[off .. off + p.len], p);
                            off += p.len;
                        }
                        local_i = scope.resolveLocal(state, subj);
                        if (local_i >= 0) {
                            saved_ty = state.locals.items[@intCast(local_i)].type_name;
                            state.locals.items[@intCast(local_i)].type_name = joined;
                        }
                    }
                }
            }
            defer if (local_i >= 0) {
                state.locals.items[@intCast(local_i)].type_name = saved_ty;
            };

            if (value_mode) {
                try compileValueArm(state, prong.body, "switch @else");
            } else {
                try compileStmtArm(state, prong.body);
            }
            const j = try emit.emitJump(state, .OP_JUMP);
            try end_jumps.append(state.allocator, j);
            continue;
        }
        if (prong.patterns.len == 0) return fail(state, "switch prong requires at least one pattern");

        var matched_jumps: std.ArrayList(usize) = .empty;
        defer matched_jumps.deinit(state.allocator);

        for (prong.patterns, 0..) |pat, i| {
            try emit.emitOp(state, .OP_GET_LOCAL);
            try emit.emitByte(state, scrut_slot);
            try expr.compileExpression(state, pat);
            try emit.emitOp(state, .OP_EQUAL);

            if (i + 1 < prong.patterns.len) {
                const miss = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
                const hit = try emit.emitJump(state, .OP_JUMP);
                try matched_jumps.append(state.allocator, hit);
                emit.patchJump(state, miss);
                try emit.emitOp(state, .OP_POP);
            }
        }

        const no_match = try emit.emitJump(state, .OP_JUMP_IF_FALSE);
        for (matched_jumps.items) |mj| emit.patchJump(state, mj);
        try emit.emitOp(state, .OP_POP);

        // Temporarily narrow subject's type_name for field loads in this arm.
        var saved_ty: ?[]const u8 = null;
        var local_i: i32 = -1;
        if (narrow_subject) |subj| {
            if (narrow_map) |map| {
                if (narrow_enum) |ename| {
                    if (prong.patterns.len == 1) {
                        if (resolveEnumVariantPattern(state, prong.patterns[0], ename)) |vname| {
                            if (map.get(vname)) |sname| {
                                local_i = scope.resolveLocal(state, subj);
                                if (local_i >= 0) {
                                    saved_ty = state.locals.items[@intCast(local_i)].type_name;
                                    state.locals.items[@intCast(local_i)].type_name = sname;
                                }
                            }
                        }
                    }
                }
            }
        }
        defer if (local_i >= 0) {
            state.locals.items[@intCast(local_i)].type_name = saved_ty;
        };

        if (value_mode) {
            try compileValueArm(state, prong.body, "switch prong");
        } else {
            try compileStmtArm(state, prong.body);
        }
        const done = try emit.emitJump(state, .OP_JUMP);
        try end_jumps.append(state.allocator, done);

        emit.patchJump(state, no_match);
        try emit.emitOp(state, .OP_POP);
    }

    for (end_jumps.items) |j| emit.patchJump(state, j);
    try scope.endScope(state);
}

/// Labeled block as a value: `blk: { break :blk v; }`
pub fn compileBlockValue(state: *CompilerState, block: *const ast.Block) !void {
    if (block.label == null) return fail(state, "value-producing block requires a label (e.g. blk: { break :blk value; })");
    try beginExprFrame(state, block.label);
    const jumps_before = state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len;
    try scope.beginScope(state);
    for (block.statements) |s| try stmt.compileStatement(state, s);
    try scope.endScope(state);
    if (state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len == jumps_before) {
        return fail(state, "value-producing block must `break` a value");
    }
    try finishExprFrame(state);
}

fn compileStmtArm(state: *CompilerState, body: *ast.Node) !void {
    try scope.beginScope(state);
    switch (body.*) {
        .block => |b| for (b.statements) |s| try stmt.compileStatement(state, s),
        else => try stmt.compileStatement(state, body),
    }
    try scope.endScope(state);
}

fn compileValueArm(state: *CompilerState, body: *ast.Node, arm_name: []const u8) !void {
    if (state.exprs.items.len == 0) return fail(state, "internal: value arm without expr frame");
    const jumps_before = state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len;
    try scope.beginScope(state);
    switch (body.*) {
        .block => |b| for (b.statements) |s| try stmt.compileStatement(state, s),
        else => try stmt.compileStatement(state, body),
    }
    try scope.endScope(state);
    if (state.exprs.items[state.exprs.items.len - 1].break_jumps.items.len == jumps_before) {
                return @import("../../errors/compile.zig").compileFailFmt(state, "{s} arm of value expression must `break` a value", .{arm_name});
    }
}

pub fn compileFor(state: *CompilerState, for_expr: *const ast.For) !void {
    try for_loop.compileFor(state, for_expr);
}

pub fn compileBreak(state: *CompilerState, brk: *const ast.Break) !void {
    if (brk.value) |val| {
        const target = try findExpr(state, brk.label);
        try expr.compileExpression(state, val);
        try emit.emitOp(state, .OP_SET_LOCAL);
        try emit.emitByte(state, target.result_slot);
        try emit.emitOp(state, .OP_POP);
        try scope.emitDefersUntil(state, target.scope_depth, .normal);
        try scope.emitPopsUntil(state, target.scope_depth);
        const jump = try emit.emitJump(state, .OP_JUMP);
        try target.break_jumps.append(state.allocator, jump);
        return;
    }

    if (brk.label) |lab| {
        if (findExprLabel(state, lab)) |target| {
            _ = target;
            return fail(state, "break to a value expression requires a value (break :label value;)");
        }
    }

    if (state.loops.items.len == 0) return fail(state, "Cannot break outside of a loop");
    const target = try findLoop(state, brk.label);
    try scope.emitDefersUntil(state, target.scope_depth, .normal);
    try scope.emitPopsUntil(state, target.scope_depth);
    const jump = try emit.emitJump(state, .OP_JUMP);
    try target.break_jumps.append(state.allocator, jump);
}

pub fn compileContinue(state: *CompilerState, cont: *const ast.Continue) !void {
    if (state.loops.items.len == 0) return fail(state, "Cannot continue outside of a loop");
    const target = try findLoop(state, cont.label);
    try scope.emitDefersUntil(state, target.scope_depth, .normal);
    try scope.emitPopsUntil(state, target.scope_depth);
    const jump = try emit.emitJump(state, .OP_JUMP);
    try target.continue_jumps.append(state.allocator, jump);
}

fn beginExprFrame(state: *CompilerState, label: ?[]const u8) !void {
    try scope.beginScope(state);
    try emit.emitOp(state, .OP_NULL);
    const slot = try scope.addLocal(state, "", false);
    try state.exprs.append(state.allocator, .{
        .scope_depth = state.scope_depth,
        .result_slot = slot,
        .label = label,
        .break_jumps = .empty,
    });
}

fn finishExprFrame(state: *CompilerState) !void {
    if (state.exprs.items.len == 0) return fail(state, "internal: finishExprFrame with empty exprs");
    var tracker = state.exprs.pop().?;
    for (tracker.break_jumps.items) |j| emit.patchJump(state, j);
    tracker.break_jumps.deinit(state.allocator);

    // Leave the result value on the stack; drop only the compiler local entry.
    if (state.locals.items.len == 0 or state.locals.items[state.locals.items.len - 1].depth != state.scope_depth) {
        return fail(state, "internal: expr result local missing");
    }
    _ = state.locals.pop();

    if (state.defer_stacks.fetchRemove(state.scope_depth)) |kv| {
        var list = kv.value;
        // Expression frames should not carry defers; run any that slipped in.
        if (list.items.len > 0) {
            var i: isize = @intCast(list.items.len);
            i -= 1;
            while (i >= 0) : (i -= 1) {
                try stmt.compileStatement(state, list.items[@intCast(i)].body);
            }
        }
        list.deinit(state.allocator);
    }
    state.scope_depth -= 1;
}

fn findExpr(state: *CompilerState, label: ?[]const u8) !*state_mod.ExprTracker {
    if (label) |lab| {
        if (findExprLabel(state, lab)) |t| return t;
                return @import("../../errors/compile.zig").compileFailFmt(state, "Cannot find value expression with label '{s}'", .{lab});
    }
    if (state.exprs.items.len == 0) {
        return fail(state, "break with value requires a value-producing @if, @switch, or labeled block");
    }
    return &state.exprs.items[state.exprs.items.len - 1];
}

fn findExprLabel(state: *CompilerState, lab: []const u8) ?*state_mod.ExprTracker {
    var i: isize = @intCast(state.exprs.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const ex = &state.exprs.items[@intCast(i)];
        if (ex.label) |ll| {
            if (std.mem.eql(u8, ll, lab)) return ex;
        }
    }
    return null;
}

fn findLoop(state: *CompilerState, label: ?[]const u8) !*state_mod.LoopTracker {
    if (label) |lab| {
        for (state.loops.items) |*loop| {
            if (loop.label) |ll| {
                if (std.mem.eql(u8, ll, lab)) return loop;
            }
        }
                return @import("../../errors/compile.zig").compileFailFmt(state, "Cannot find loop with label '{s}'", .{lab});
    }
    return &state.loops.items[state.loops.items.len - 1];
}

fn fail(state: *CompilerState, msg: []const u8) error{CompileError} {
    return @import("../../errors/compile.zig").compileFailFmt(state, "{s}", .{msg});
}
