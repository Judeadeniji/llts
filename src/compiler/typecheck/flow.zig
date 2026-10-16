const std = @import("std");
const ast = @import("../../ast/root.zig");
const ir = @import("ir.zig");
const from_ast = @import("from_ast.zig");
const state_mod = @import("../state.zig");
const cfg_mod = @import("cfg.zig");

pub const BlockId = cfg_mod.BlockId;

/// Errors raised by the flow pass — a subset of `root.TypecheckError`, so
/// callers can propagate them unchanged. Declared explicitly because the
/// fact-extraction helpers are mutually recursive and Zig cannot infer a
/// single error set across that cycle.
pub const FlowError = error{ OutOfMemory, CompileError, Overflow, InvalidCharacter };

/// Per-variable type state at a program point. Only locals that have been
/// narrowed or reassigned appear; anything absent falls back to the declared
/// type in the typechecker's `Env`.
pub const FlowEnv = struct {
    allocator: std.mem.Allocator,
    /// Variable name → current (possibly narrowed) type.
    types: std.StringHashMap(ir.Type),

    pub fn init(allocator: std.mem.Allocator) FlowEnv {
        return .{ .allocator = allocator, .types = std.StringHashMap(ir.Type).init(allocator) };
    }

    pub fn deinit(self: *FlowEnv) void {
        self.types.deinit();
    }

    pub fn clone(self: *const FlowEnv) !FlowEnv {
        var out = FlowEnv.init(self.allocator);
        errdefer out.deinit();
        var it = self.types.iterator();
        while (it.next()) |e| {
            try out.types.put(e.key_ptr.*, e.value_ptr.*);
        }
        return out;
    }

    pub fn get(self: *const FlowEnv, name: []const u8) ?ir.Type {
        return self.types.get(name);
    }

    pub fn put(self: *FlowEnv, name: []const u8, t: ir.Type) !void {
        try self.types.put(name, t);
    }

    /// Structural equality of the narrowed-type maps.
    pub fn eql(self: *const FlowEnv, other: *const FlowEnv) bool {
        if (self.types.count() != other.types.count()) return false;
        var it = self.types.iterator();
        while (it.next()) |e| {
            const ov = other.types.get(e.key_ptr.*) orelse return false;
            if (!ir.typeEquals(e.value_ptr.*, ov)) return false;
        }
        return true;
    }
};

/// Lattice join of two types at a control-flow merge:
///   • equal → that type
///   • one ⊑ other → the supertype
///   • null ∪ T → ?T
///   • error ∪ T → T|error
///   • otherwise → union of both arms (deduped via `ta.unionType`)
pub fn joinTypes(ta: ir.TypeAlloc, a: ir.Type, b: ir.Type) !ir.Type {
    if (ir.typeEquals(a, b)) return a;
    if (ir.involvesUnknown(a) or ir.involvesUnknown(b)) return ir.TUnknown;
    if (ir.isSubtype(a, b)) return b;
    if (ir.isSubtype(b, a)) return a;
    // Optional folding: T ∪ null → ?T (represented as union with null).
    if (a == .null and b != .null) {
        if (ir.optionalPayload(b)) |p| {
            _ = p;
            return b; // already optional
        }
        var arms = [_]ir.Type{ a, b };
        return try ta.unionType(&arms);
    }
    if (b == .null and a != .null) {
        if (ir.optionalPayload(a)) |p| {
            _ = p;
            return a;
        }
        var arms = [_]ir.Type{ b, a };
        return try ta.unionType(&arms);
    }
    // Error folding: error ∪ T → T|error.
    if ((a == .error_ or ir.isErrorArm(a)) and b != .error_ and !ir.isErrorArm(b)) {
        var arms = [_]ir.Type{ b, ir.TError };
        return try ta.unionType(&arms);
    }
    if ((b == .error_ or ir.isErrorArm(b)) and a != .error_ and !ir.isErrorArm(a)) {
        var arms = [_]ir.Type{ a, ir.TError };
        return try ta.unionType(&arms);
    }
    var arms = [_]ir.Type{ a, b };
    return try ta.unionType(&arms);
}

/// Join two flow environments: for each variable present in either side,
/// merge the types.  A variable narrowed on only one incoming edge loses
/// its narrowing (the other edge still sees the wide type) unless the
/// wide type equals the narrowed one — handled by only tracking deltas.
pub fn joinFlowEnvs(ta: ir.TypeAlloc, a: *const FlowEnv, b: *const FlowEnv) !FlowEnv {
    var out = FlowEnv.init(ta.allocator);
    errdefer out.deinit();

    var it = a.types.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const ta_ = e.value_ptr.*;
        if (b.types.get(name)) |tb| {
            const j = try joinTypes(ta, ta_, tb);
            try out.types.put(name, j);
        } else {
            // Narrowed only on `a`'s path; `b` still has the declared type.
            // We don't know the declared type here, so drop the narrowing.
            // (Declared-type recovery is the typechecker Env's job.)
        }
    }
    var itb = b.types.iterator();
    while (itb.next()) |e| {
        // Narrowed only on b's path — drop (same rationale as above).
        _ = e;
    }
    return out;
}

/// One narrowing fact extracted from a condition.
pub const NarrowFact = struct {
    /// Variable being narrowed (primary name, no `$`).
    name: []const u8,
    /// Type on the true edge (null = no fact).
    true_type: ?ir.Type,
    /// Type on the false edge (null = no fact).
    false_type: ?ir.Type,
};

/// Extract narrowing facts from a boolean condition expression.
/// Returns facts into `out` (cleared first).  Never fails hard — unknown
/// shapes simply produce no facts.
pub fn extractFacts(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    cond: *ast.Node,
    out: *std.ArrayList(NarrowFact),
) FlowError!void {
    out.clearRetainingCapacity();
    try extractFactsInner(state, ta, env, cond, out, false);
}

fn extractFactsInner(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    cond: *ast.Node,
    out: *std.ArrayList(NarrowFact),
    negated: bool,
) from_ast.FromAstError!void {
    switch (cond.*) {
        .binary => |b| try extractBinaryFacts(state, ta, env, &b, out, negated),
        .unary => |u| {
            if (std.mem.eql(u8, u.operator, "!")) {
                try extractFactsInner(state, ta, env, u.arg, out, !negated);
            }
        },
        .call => |c| try extractCallFacts(state, ta, env, &c, out, negated),
        .primary => |p| {
            // Bare identifier condition: `@if (x)` / `@if (!x)` / `@if (x | v)`
            // where `x` is optional — true edge means non-null.
            if (p.kind == .identifier or p.kind == .register) {
                try truthinessFact(state, ta, env, p.name, negated, out);
            }
        },
        else => {},
    }
}

/// Bare optional in boolean position: true edge → payload, false edge → null.
/// `negated` (`@if (!x)`) swaps the edges.
fn truthinessFact(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    name: []const u8,
    negated: bool,
    out: *std.ArrayList(NarrowFact),
) FlowError!void {
    const cur = lookupVarType(state, env, name) orelse return;
    const payload = ir.optionalPayload(ir.peelDefined(cur)) orelse return;
    try out.append(ta.allocator, .{
        .name = name,
        .true_type = if (negated) ir.TNull else payload,
        .false_type = if (negated) payload else ir.TNull,
    });
}

fn lookupVarType(
    state: *state_mod.CompilerState,
    env: *const FlowEnv,
    name: []const u8,
) ?ir.Type {
    _ = state;
    return env.get(name);
}

fn extractBinaryFacts(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    b: *const ast.Binary,
    out: *std.ArrayList(NarrowFact),
    negated: bool,
) from_ast.FromAstError!void {
    const op = b.operator;

    // `a && b` — facts from `a` on the true edge also hold when `a` is
    // evaluated on the path to `b`; on the false edge nothing precise.
    if (std.mem.eql(u8, op, "&&")) {
        if (!negated) {
            try extractFactsInner(state, ta, env, b.left, out, false);
            // Right-side facts are computed in a context where left is true,
            // but our FlowEnv is the entry state — approximate by also
            // extracting from the right (sound: we only add facts that are
            // conjunctions the checker will re-verify).
            var right_facts: std.ArrayList(NarrowFact) = .empty;
            defer right_facts.deinit(ta.allocator);
            try extractFactsInner(state, ta, env, b.right, &right_facts, false);
            for (right_facts.items) |f| try out.append(ta.allocator, f);
        } else {
            // !(a && b) ≡ !a || !b — no single-edge fact without knowing which.
        }
        return;
    }
    // `a || b` — dual.
    if (std.mem.eql(u8, op, "||")) {
        if (negated) {
            try extractFactsInner(state, ta, env, b.left, out, true);
            var right_facts: std.ArrayList(NarrowFact) = .empty;
            defer right_facts.deinit(ta.allocator);
            try extractFactsInner(state, ta, env, b.right, &right_facts, true);
            for (right_facts.items) |f| try out.append(ta.allocator, f);
        }
        return;
    }

    const is_eq = std.mem.eql(u8, op, "==");
    const is_ne = std.mem.eql(u8, op, "!=");
    if (!is_eq and !is_ne) return;

    // Effective polarity: `x != null` under negation behaves like `==`.
    const eq_means_true = is_eq;
    const ne_means_true = is_ne;

    // `x == null` / `x != null`
    if (isNullLiteral(b.right)) {
        if (try nullCheckFact(state, ta, env, b.left, eq_means_true, negated, out)) return;
    }
    if (isNullLiteral(b.left)) {
        if (try nullCheckFact(state, ta, env, b.right, eq_means_true, negated, out)) return;
    }

    // `x.kind == Enum.Variant` (and reversed)
    if (try kindDiscrimFact(state, ta, env, b, eq_means_true, negated, out)) return;

    // `@isError(x) == true/false` — rare but legal.
    _ = ne_means_true;
}

fn isNullLiteral(node: *ast.Node) bool {
    return node.* == .literal and node.literal.literal_type == .null;
}

/// `x == null` / `x != null` where `x` is a primary identifier whose current
/// type is optional (`?T` or `T | null`).
fn nullCheckFact(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    subject: *ast.Node,
    eq_on_true: bool,
    negated: bool,
    out: *std.ArrayList(NarrowFact),
) !bool {
    if (subject.* != .primary) return false;
    const p = subject.primary;
    if (p.kind != .identifier and p.kind != .register) return false;
    const cur = lookupVarType(state, env, p.name) orelse return false;
    const payload = ir.optionalPayload(ir.peelDefined(cur)) orelse return false;

    // When the condition is true: `== null` → payload is null; `!= null` → payload type.
    // When false: the opposite.  Apply negation by swapping which edge is "true".
    const true_is_null = if (negated) !eq_on_true else eq_on_true;
    const true_type: ?ir.Type = if (true_is_null) ir.TNull else payload;
    const false_type: ?ir.Type = if (true_is_null) payload else ir.TNull;
    try out.append(ta.allocator, .{
        .name = p.name,
        .true_type = true_type,
        .false_type = false_type,
    });
    return true;
}

/// `subject.kind == Enum.Variant` on a discriminated struct union.
fn kindDiscrimFact(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    b: *const ast.Binary,
    eq_on_true: bool,
    negated: bool,
    out: *std.ArrayList(NarrowFact),
) !bool {
    // Identify subject.kind on the left and Enum.Variant on the right (or swapped).
    var subject_node: ?*ast.Node = null;
    var variant_node: ?*ast.Node = null;
    if (isKindMember(b.left)) {
        subject_node = b.left.member.object;
        variant_node = b.right;
    } else if (isKindMember(b.right)) {
        subject_node = b.right.member.object;
        variant_node = b.left;
    } else return false;

    const subject = subject_node.?;
    if (subject.* != .primary) return false;
    const pname = subject.primary.name;
    if (subject.primary.kind != .identifier and subject.primary.kind != .register) return false;

    const cur = lookupVarType(state, env, pname) orelse return false;
    const peeled = ir.peelDefined(cur);
    if (peeled != .union_) return false;

    // Resolve enum variant name from the pattern node.
    const vname = resolveVariantName(variant_node.?) orelse return false;
    const ename = resolveVariantEnum(state, variant_node.?) orelse return false;

    // Build variant → struct map for the union.
    const disp = try ir.displayTypeAlloc(ta.allocator, peeled);
    var info = (try from_ast.discrimVariantMap(state, ta.allocator, disp)) orelse return false;
    defer info.map.deinit();

    const arm_struct = info.map.get(vname) orelse return false;
    if (!std.mem.eql(u8, info.enum_name, ename)) return false;

    // True edge: subject is the matching struct arm.
    // False edge: remaining arms (if any).
    const true_is_match = if (negated) !eq_on_true else eq_on_true;
    const match_type: ir.Type = .{ .struct_ = arm_struct };

    var remaining: std.ArrayList(ir.Type) = .empty;
    defer remaining.deinit(ta.allocator);
    var it = info.map.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.key_ptr.*, vname)) {
            try remaining.append(ta.allocator, .{ .struct_ = e.value_ptr.* });
        }
    }
    const else_type: ?ir.Type = if (remaining.items.len == 0)
        ir.TNever
    else if (remaining.items.len == 1)
        remaining.items[0]
    else
        try ta.unionType(remaining.items);

    try out.append(ta.allocator, .{
        .name = pname,
        .true_type = if (true_is_match) match_type else else_type,
        .false_type = if (true_is_match) else_type else match_type,
    });
    return true;
}

fn isKindMember(node: *ast.Node) bool {
    if (node.* != .member) return false;
    const m = node.member;
    return m.property.* == .primary and std.mem.eql(u8, m.property.primary.name, "kind");
}

fn resolveVariantName(node: *ast.Node) ?[]const u8 {
    if (node.* != .member) return null;
    const m = node.member;
    if (m.property.* != .primary) return null;
    return m.property.primary.name;
}

fn resolveVariantEnum(state: *state_mod.CompilerState, node: *ast.Node) ?[]const u8 {
    if (node.* != .member) return null;
    const m = node.member;
    return from_ast.resolveEnumName(state, m.object);
}

/// `@isError(x)` — narrow `x` to `error` on true, success arm on false.
fn extractCallFacts(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    c: *const ast.Call,
    out: *std.ArrayList(NarrowFact),
    negated: bool,
) from_ast.FromAstError!void {
    if (c.callee.* != .primary) return;
    if (!std.mem.eql(u8, c.callee.primary.name, "@isError")) return;
    if (c.args.len != 1) return;
    if (c.args[0].* != .primary) return;
    const p = c.args[0].primary;
    if (p.kind != .identifier and p.kind != .register) return;

    const cur = lookupVarType(state, env, p.name) orelse return;
    const peeled = ir.peelDefined(cur);
    if (!ir.isErrorUnion(peeled) and !ir.isErrorArm(peeled)) return;

    const success = try ir.unwrapError(ta, peeled);
    const true_is_error = !negated;
    try out.append(ta.allocator, .{
        .name = p.name,
        .true_type = if (true_is_error) ir.TError else success,
        .false_type = if (true_is_error) success else ir.TError,
    });
}

/// Transfer function: apply a statement to a flow env.
/// Declarations and simple assignments refine variable types.
pub fn transferStmt(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *FlowEnv,
    node: *ast.Node,
) FlowError!void {
    switch (node.*) {
        .declaration => |d| {
            // `$x: T = v` / `$x = v`
            var t: ir.Type = ir.TUnknown;
            if (d.type_annotation) |ann| {
                t = from_ast.typeFromAst(ann, state, ta) catch ir.TUnknown;
            } else {
                t = inferRhsType(state, ta, env, d.value);
            }
            if (t != .unknown) try env.put(d.name, t);
        },
        .assignment => |a| {
            if (a.left.* == .primary) {
                const p = a.left.primary;
                if (p.kind == .identifier or p.kind == .register) {
                    const t = inferRhsType(state, ta, env, a.right);
                    // Only refine when we learned something concrete;
                    // otherwise keep the previous (possibly declared) state.
                    if (t != .unknown) try env.put(p.name, t);
                }
            }
        },
        else => {},
    }
}

/// Best-effort RHS type for flow refinement.  Returns `unknown` when the
/// expression shape is not one we model — the caller keeps the prior type.
/// Display parsing passes `state = null`: diagnostics must never fire from
/// the pre-pass (the walker reports them), and unresolvable names merely
/// degrade to `unknown` / a non-subtype that the `lookup` guard rejects.
fn inferRhsType(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    env: *const FlowEnv,
    node: *ast.Node,
) ir.Type {
    switch (node.*) {
        .literal => |lit| switch (lit.literal_type) {
            .null => return ir.TNull,
            .boolean => return ir.TBool,
            .string => return ir.TString,
            .number, .hex, .octal, .binary => {
                if (std.mem.indexOfScalar(u8, lit.value, '.') != null or
                    std.mem.indexOfScalar(u8, lit.value, 'e') != null or
                    std.mem.indexOfScalar(u8, lit.value, 'E') != null)
                    return ir.TF64;
                return ir.TInt;
            },
        },
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) {
                if (env.get(p.name)) |t| return t;
            }
            return ir.TUnknown;
        },
        .call => |c| {
            if (c.callee.* != .primary) return ir.TUnknown;
            const callee_name = c.callee.primary.name;
            // `@as(T, v)` → T.
            if (std.mem.eql(u8, callee_name, "@as") and c.args.len == 2) {
                const disp = (from_ast.typeAstToDisplay(c.args[0], null) catch return ir.TUnknown) orelse return ir.TUnknown;
                return from_ast.parseDisplayType(null, ta, disp, null) catch ir.TUnknown;
            }
            // Named function → its declared return type.
            if (state.functions.get(callee_name)) |def| {
                if (def.return_type) |rt| {
                    return from_ast.parseDisplayType(null, ta, rt, null) catch ir.TUnknown;
                }
            }
            return ir.TUnknown;
        },
        .error_expr => return ir.TError,
        .struct_init => |si| {
            // `User { … }` → `User` (resolveStructName never emits diagnostics).
            if (from_ast.resolveStructName(state, si.type_expr)) |sn| {
                return .{ .struct_ = sn };
            }
            return ir.TUnknown;
        },
        else => return ir.TUnknown,
    }
}

/// Per-block dataflow results: the flow env at block entry.
pub const FlowResults = struct {
    allocator: std.mem.Allocator,
    /// Entry env for each reachable block (absent = unreachable).
    block_in: std.AutoHashMap(BlockId, FlowEnv),
    /// Flow env at the start of each statement node (for narrowing during
    /// the typechecker's AST walk).
    stmt_in: std.AutoHashMap(*ast.Node, FlowEnv),

    pub fn init(allocator: std.mem.Allocator) FlowResults {
        return .{
            .allocator = allocator,
            .block_in = std.AutoHashMap(BlockId, FlowEnv).init(allocator),
            .stmt_in = std.AutoHashMap(*ast.Node, FlowEnv).init(allocator),
        };
    }

    pub fn deinit(self: *FlowResults) void {
        var it = self.block_in.valueIterator();
        while (it.next()) |v| v.deinit();
        self.block_in.deinit();
        var sit = self.stmt_in.valueIterator();
        while (sit.next()) |v| v.deinit();
        self.stmt_in.deinit();
    }

    /// Snapshot of the flow env for a statement, if analyzed.
    pub fn stmtEnv(self: *const FlowResults, node: *ast.Node) ?*const FlowEnv {
        return self.stmt_in.getPtr(node);
    }
};

/// Maximum fixpoint iterations before widening loop-carried types to unknown.
const MAX_ITER = 8;

/// Run forward dataflow over `cfg` starting from `entry_env`.
/// `declared` provides the declared type of locals for join fallback.
pub fn analyze(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    cfg: *const cfg_mod.CFG,
    entry_env: FlowEnv,
) FlowError!FlowResults {
    var results = FlowResults.init(ta.allocator);
    errdefer results.deinit();

    // in[entry] = entry_env
    const entry_copy = try entry_env.clone();
    try results.block_in.put(cfg.entry, entry_copy);

    var worklist: std.ArrayList(BlockId) = .empty;
    defer worklist.deinit(ta.allocator);
    try worklist.append(ta.allocator, cfg.entry);

    var iter_count = std.AutoHashMap(BlockId, u32).init(ta.allocator);
    defer iter_count.deinit();

    var facts: std.ArrayList(NarrowFact) = .empty;
    defer facts.deinit(ta.allocator);

    while (worklist.items.len > 0) {
        const bid = worklist.items[worklist.items.len - 1];
        _ = worklist.pop();

        const in_ptr = results.block_in.getPtr(bid) orelse continue;
        // Work on a local copy so we don't mutate the stored in-state.
        var cur = try in_ptr.clone();
        defer cur.deinit();

        const block = &cfg.blocks.items[bid];

        // Transfer each statement.
        for (block.stmts.items) |s| {
            // Record the env at the start of this statement.
            const snap = try cur.clone();
            // Put takes ownership of the map contents (shallow type copies).
            const gop = try results.stmt_in.getOrPut(s);
            if (gop.found_existing) {
                gop.value_ptr.deinit();
            }
            gop.value_ptr.* = snap;

            try transferStmt(state, ta, &cur, s);
        }

        // Terminator: compute successor envs.
        switch (block.term) {
            .goto => |t| {
                try propagate(&results, &worklist, &iter_count, t, &cur, cfg, ta);
            },
            .br => |br| {
                var true_env = try cur.clone();
                defer true_env.deinit();
                var false_env = try cur.clone();
                defer false_env.deinit();

                try applyBranchFacts(state, ta, &true_env, &false_env, br.cond);

                try propagate(&results, &worklist, &iter_count, br.true_bb, &true_env, cfg, ta);
                try propagate(&results, &worklist, &iter_count, br.false_bb, &false_env, cfg, ta);
            },
            .switch_ => |sw| {
                // For each arm, narrow the switch subject when possible.
                var covered = std.StringHashMap(void).init(ta.allocator);
                defer covered.deinit();

                // Detect `subject.kind` discriminant switch.
                var subject_name: ?[]const u8 = null;
                var enum_name: ?[]const u8 = null;
                if (sw.cond.* == .member) {
                    const m = sw.cond.member;
                    if (m.property.* == .primary and std.mem.eql(u8, m.property.primary.name, "kind") and
                        m.object.* == .primary)
                    {
                        subject_name = m.object.primary.name;
                    }
                }

                for (sw.arms) |arm| {
                    var arm_env = try cur.clone();
                    defer arm_env.deinit();

                    if (subject_name) |sn| {
                        if (cur.get(sn)) |subj_t| {
                            const peeled = ir.peelDefined(subj_t);
                            if (peeled == .union_) {
                                const disp = try ir.displayTypeAlloc(ta.allocator, peeled);
                                if (try from_ast.discrimVariantMap(state, ta.allocator, disp)) |found| {
                                    var info = found;
                                    defer info.map.deinit();
                                    enum_name = info.enum_name;
                                    if (arm.is_else) {
                                        // Remaining arms after `covered`.
                                        var remaining: std.ArrayList(ir.Type) = .empty;
                                        defer remaining.deinit(ta.allocator);
                                        var it = info.map.iterator();
                                        while (it.next()) |e| {
                                            if (!covered.contains(e.key_ptr.*)) {
                                                try remaining.append(ta.allocator, .{ .struct_ = e.value_ptr.* });
                                            }
                                        }
                                        if (remaining.items.len == 1) {
                                            try arm_env.put(sn, remaining.items[0]);
                                        } else if (remaining.items.len > 1) {
                                            try arm_env.put(sn, try ta.unionType(remaining.items));
                                        }
                                    } else if (arm.patterns.len == 1) {
                                        if (resolveVariantName(arm.patterns[0])) |vn| {
                                            try covered.put(vn, {});
                                            if (info.map.get(vn)) |sname| {
                                                try arm_env.put(sn, .{ .struct_ = sname });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    try propagate(&results, &worklist, &iter_count, arm.bb, &arm_env, cfg, ta);
                }
                try propagate(&results, &worklist, &iter_count, sw.else_bb, &cur, cfg, ta);
            },
            .ret => {},
            .jump => |t| {
                try propagate(&results, &worklist, &iter_count, t, &cur, cfg, ta);
            },
            .loop => |t| {
                try propagate(&results, &worklist, &iter_count, t, &cur, cfg, ta);
            },
            .unreachable_ => {},
        }
    }

    return results;
}

fn propagate(
    results: *FlowResults,
    worklist: *std.ArrayList(BlockId),
    iter_count: *std.AutoHashMap(BlockId, u32),
    target: BlockId,
    out_env: *const FlowEnv,
    cfg: *const cfg_mod.CFG,
    ta: ir.TypeAlloc,
) FlowError!void {
    _ = cfg;
    const gop = try results.block_in.getOrPut(target);
    if (!gop.found_existing) {
        gop.value_ptr.* = try out_env.clone();
        try worklist.append(ta.allocator, target);
        try iter_count.put(target, 1);
        return;
    }
    // Join with existing.
    const joined = try joinFlowEnvs(ta, gop.value_ptr, out_env);
    const changed = !gop.value_ptr.eql(&joined);
    // Free old, install joined.
    gop.value_ptr.deinit();
    gop.value_ptr.* = joined;
    if (changed) {
        const n = (iter_count.get(target) orelse 0) + 1;
        try iter_count.put(target, n);
        if (n <= MAX_ITER) {
            try worklist.append(ta.allocator, target);
        } else {
            // Widening: drop all narrowings at this block so types revert to
            // the declared types from the typechecker Env.  Guarantees
            // termination in the presence of recursive type growth.
            var it = gop.value_ptr.types.keyIterator();
            var to_remove: std.ArrayList([]const u8) = .empty;
            defer to_remove.deinit(ta.allocator);
            while (it.next()) |k| try to_remove.append(ta.allocator, k.*);
            for (to_remove.items) |k| _ = gop.value_ptr.types.remove(k);
        }
    }
}

/// Apply condition-derived facts to true/false envs.
fn applyBranchFacts(
    state: *state_mod.CompilerState,
    ta: ir.TypeAlloc,
    true_env: *FlowEnv,
    false_env: *FlowEnv,
    cond: *ast.Node,
) FlowError!void {
    var facts: std.ArrayList(NarrowFact) = .empty;
    defer facts.deinit(ta.allocator);
    try extractFacts(state, ta, true_env, cond, &facts);
    for (facts.items) |f| {
        if (f.true_type) |tt| try true_env.put(f.name, tt);
        if (f.false_type) |ft| try false_env.put(f.name, ft);
    }
}
