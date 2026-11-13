//! Binding-facts analysis: walk function bodies and record per-binding
//! read / assigned / reassigned flags into `CompilerState`.
//!
//! These facts drive `var` vs `const` and `_ =` suppression in the native
//! emitter (unit.zig + stmt.zig) so the emitter never re-walks the AST.
//!
//! Keys written into CompilerState:
//!   state.binding_facts       : *ast.Node (declaration node) → BindingFacts
//!   state.param_facts         : *const ast.Param              → BindingFacts
//!   state.for_capture_facts   : *const ast.Node (for_expr)   → [2]BindingFacts
//!   state.if_capture_facts    : *const ast.Node (if_expr)    → BindingFacts

const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");

// ── public entry point ───────────────────────────────────────────────────────

/// Walk every function body in `state.functions` and all top-level statements,
/// populating `state.binding_facts`, `state.param_facts`,
/// `state.for_capture_facts`, and `state.if_capture_facts`.
/// Keys written into CompilerState:
///   state.binding_facts       : *ast.Node (declaration node) → BindingFacts
///   state.param_facts         : *const ast.Param              → BindingFacts
///   state.for_capture_facts   : *const ast.Node (for_expr)   → [2]BindingFacts
///   state.if_capture_facts    : *const ast.Node (if_expr)    → BindingFacts
pub fn analyze(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    // Escape facts need a fixpoint: whether `&x` escapes at a call site depends
    // on whether the callee retains that parameter, which depends on its own
    // call sites. The walk is idempotent (it only ever ORs flags in), so repeat
    // it until nothing new is learned. Bounded by the number of pointer params
    // in the program; the cap is a safety net, not the expected trip count.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const before = state.addr_taken_decls.count() + state.addr_taken_params.count() + state.escaping_params.count();
        try walkProgram(state, doc);
        const after = state.addr_taken_decls.count() + state.addr_taken_params.count() + state.escaping_params.count();
        if (after == before) break;
    }

    // Synchronize closure captures with addr_taken facts: any capture that is mutated
    // must have its declaration in addr_taken_decls (boxed in immortal heap cell), and any
    // capture whose declaration is addr_taken must capture by pointer (is_mutated = true).
    var cit = state.closures.valueIterator();
    while (cit.next()) |info| {
        for (info.captures) |*cap| {
            var bit = state.binding_facts.keyIterator();
            while (bit.next()) |decl_node| {
                if (decl_node.*.* == .declaration) {
                    if (std.mem.eql(u8, decl_node.*.declaration.name, cap.name)) {
                        if (cap.is_mutated) {
                            try state.addr_taken_decls.put(decl_node.*.declaration.value, {});
                        } else if (state.addr_taken_decls.contains(decl_node.*.declaration.value)) {
                            cap.is_mutated = true;
                        }
                    }
                }
            }
        }
    }
}

fn walkProgram(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    // 1. Analyze every registered function (includes methods, module functions, generic instances)
    var it = state.functions.valueIterator();
    while (it.next()) |def| {
        if (def.node.* == .function_decl) {
            try analyzeFunction(state, def.node.function_decl);
        }
    }

    // 2. Analyze top-level statements in doc and module docs
    try analyzeTopLevelStatements(state, doc.statements);
    for (state.module_docs.items) |mdoc| {
        try analyzeTopLevelStatements(state, mdoc.statements);
    }
}

fn analyzeTopLevelStatements(state: *state_mod.CompilerState, stmts: []*ast.Node) !void {
    var ctx = Ctx.init(state);
    defer ctx.deinit();

    try ctx.pushScope();
    for (stmts) |s| {
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => continue,
            else => try ctx.walkStmt(s),
        }
    }
    ctx.popScope();
}

// ── per-function walk ────────────────────────────────────────────────────────

fn analyzeFunction(state: *state_mod.CompilerState, f: ast.FunctionDecl) !void {
    var ctx = Ctx.init(state);
    defer ctx.deinit();
    ctx.in_function = true;

    try ctx.pushScope();
    if (f.params.* == .params) {
        for (f.params.params.params) |*p| {
            // `getOrPut`: `analyze` walks the program several times to reach the
            // escape fixpoint, and a plain `put` would wipe the flags recorded by
            // the earlier rounds.
            _ = try state.param_facts.getOrPut(p);
            try ctx.putParam(p.name, p);
        }
    }

    try ctx.walkStmt(f.body);
    ctx.popScope();
}

// ── analysis context ─────────────────────────────────────────────────────────

const ScopeEntry = union(enum) {
    decl: *ast.Node,
    param: *const ast.Param,
    for_cap: struct {
        /// The *ast.Node carrying the .for_expr variant (stable address).
        for_node: *const ast.Node,
        index: usize,
    },
    /// The *ast.Node carrying the .if_expr variant (stable address).
    if_cap: *const ast.Node,
};

const Scope = std.StringHashMap(ScopeEntry);

const Ctx = struct {
    state: *state_mod.CompilerState,
    scopes: std.ArrayList(Scope) = .empty,
    /// Escape facts only matter for function bodies: module-level storage is
    /// allocated immortal already.
    in_function: bool = false,
    closure_base_depth: ?usize = null,

    fn init(state: *state_mod.CompilerState) Ctx {
        return .{
            .state = state,
            .scopes = .empty,
        };
    }

    fn deinit(ctx: *Ctx) void {
        for (ctx.scopes.items) |*s| s.deinit();
        ctx.scopes.deinit(ctx.state.allocator);
    }

    fn pushScope(ctx: *Ctx) !void {
        try ctx.scopes.append(ctx.state.allocator, Scope.init(ctx.state.allocator));
    }

    fn popScope(ctx: *Ctx) void {
        if (ctx.scopes.items.len == 0) return;
        var s = ctx.scopes.pop().?;
        s.deinit();
    }

    fn putDecl(ctx: *Ctx, name: []const u8, node: *ast.Node) !void {
        const scope = &ctx.scopes.items[ctx.scopes.items.len - 1];
        try scope.put(name, .{ .decl = node });
    }

    fn putParam(ctx: *Ctx, name: []const u8, p: *const ast.Param) !void {
        const scope = &ctx.scopes.items[ctx.scopes.items.len - 1];
        try scope.put(name, .{ .param = p });
    }

    fn putForCapture(ctx: *Ctx, name: []const u8, for_node: *const ast.Node, index: usize) !void {
        const scope = &ctx.scopes.items[ctx.scopes.items.len - 1];
        try scope.put(name, .{ .for_cap = .{ .for_node = for_node, .index = index } });
    }

    fn putIfCapture(ctx: *Ctx, name: []const u8, if_node: *const ast.Node) !void {
        const scope = &ctx.scopes.items[ctx.scopes.items.len - 1];
        try scope.put(name, .{ .if_cap = if_node });
    }

    fn markRead(ctx: *Ctx, name: []const u8) void {
        var i = ctx.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &ctx.scopes.items[i];
            if (scope.get(name)) |entry| {
                switch (entry) {
                    .decl => |node| {
                        if (ctx.state.binding_facts.getPtr(node)) |f| f.read = true;
                    },
                    .param => |p| {
                        if (ctx.state.param_facts.getPtr(p)) |f| f.read = true;
                    },
                    .for_cap => |fc| {
                        if (ctx.state.for_capture_facts.getPtr(fc.for_node)) |slots| {
                            if (fc.index < 2) slots[fc.index].read = true;
                        }
                    },
                    .if_cap => |if_node| {
                        if (ctx.state.if_capture_facts.getPtr(if_node)) |f| f.read = true;
                    },
                }
                return;
            }
        }
    }

    fn markAssigned(ctx: *Ctx, name: []const u8) void {
        var i = ctx.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &ctx.scopes.items[i];
            if (scope.get(name)) |entry| {
                if (ctx.closure_base_depth) |base| {
                    if (i < base) {
                        switch (entry) {
                            .decl => |node| ctx.state.addr_taken_decls.put(node.declaration.value, {}) catch {},
                            .param => |p| ctx.state.addr_taken_params.put(p, {}) catch {},
                            else => {},
                        }
                    }
                }
                switch (entry) {
                    .decl => |node| {
                        if (ctx.state.binding_facts.getPtr(node)) |f| f.assigned = true;
                    },
                    .param => |p| {
                        if (ctx.state.param_facts.getPtr(p)) |f| f.assigned = true;
                    },
                    .for_cap => |fc| {
                        if (ctx.state.for_capture_facts.getPtr(fc.for_node)) |slots| {
                            if (fc.index < 2) slots[fc.index].assigned = true;
                        }
                    },
                    .if_cap => |if_node| {
                        if (ctx.state.if_capture_facts.getPtr(if_node)) |f| f.assigned = true;
                    },
                }
                return;
            }
        }
    }

    fn markReassigned(ctx: *Ctx, name: []const u8) void {
        var i = ctx.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &ctx.scopes.items[i];
            if (scope.get(name)) |entry| {
                if (ctx.closure_base_depth) |base| {
                    if (i < base) {
                        switch (entry) {
                            .decl => |node| ctx.state.addr_taken_decls.put(node.declaration.value, {}) catch {},
                            .param => |p| ctx.state.addr_taken_params.put(p, {}) catch {},
                            else => {},
                        }
                    }
                }
                switch (entry) {
                    .decl => |node| {
                        if (ctx.state.binding_facts.getPtr(node)) |f| {
                            f.assigned = true;
                            f.reassigned = true;
                        }
                    },
                    .param => |p| {
                        if (ctx.state.param_facts.getPtr(p)) |f| {
                            f.assigned = true;
                            f.reassigned = true;
                        }
                    },
                    .for_cap => |fc| {
                        if (ctx.state.for_capture_facts.getPtr(fc.for_node)) |slots| {
                            if (fc.index < 2) {
                                slots[fc.index].assigned = true;
                                slots[fc.index].reassigned = true;
                            }
                        }
                    },
                    .if_cap => |if_node| {
                        if (ctx.state.if_capture_facts.getPtr(if_node)) |f| {
                            f.assigned = true;
                            f.reassigned = true;
                        }
                    },
                }
                return;
            }
        }
    }

    fn lookup(ctx: *Ctx, name: []const u8) ?ScopeEntry {
        var i = ctx.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (ctx.scopes.items[i].get(name)) |entry| return entry;
        }
        return null;
    }

    /// Record that `&place` hands out a pointer that outlives this frame.
    ///
    /// Consumers rely on this: the bytecode backend allocates the binding's
    /// storage below the immortal floor, and the native emitter boxes it in
    /// immortal heap, so a pointer stored into a field (or returned) cannot
    /// dangle once the frame is rewound. Keyed the way each consumer sees the
    /// binding: locals by their initializer node, parameters by the `ast.Param`.
    ///
    /// `&obj.field` counts: the pointer points into `obj`, so `obj` itself has
    /// to outlive the frame.
    fn markAddrTaken(ctx: *Ctx, place: *ast.Node) anyerror!void {
        if (!ctx.in_function) return; // globals already live forever
        var root = place;
        while (true) {
            switch (root.*) {
                .member => |m| root = m.object,
                .index => |ix| root = ix.object,
                .primary => break,
                else => return,
            }
        }
        if (root.primary.kind != .identifier and root.primary.kind != .register) return;
        const entry = ctx.lookup(root.primary.name) orelse return;
        switch (entry) {
            .decl => |decl_node| try ctx.state.addr_taken_decls.put(decl_node.declaration.value, {}),
            .param => |p| try ctx.state.addr_taken_params.put(p, {}),
            // Loop/if captures are re-bound per iteration by the backends; a
            // `&capture` is only reachable from inside that iteration.
            .for_cap, .if_cap => {},
        }
    }

    /// Note that `expr` is stored somewhere that may outlive the frame. Only
    /// then does an address-taken local need immortal storage: a pointer that is
    /// read, compared, or passed to a callee that does not keep it dies with the
    /// frame and can stay on the stack.
    fn noteEscape(ctx: *Ctx, expr: *ast.Node) anyerror!void {
        var inner = expr;
        while (true) {
            switch (inner.*) {
                .comptime_expr => |c| inner = c.expr,
                .try_expr => |t| inner = t.expression,
                .unwrap_expr => |u| inner = u.expression,
                // `@as(T, ptr)` / `@constCast(ptr)` are value-preserving.
                .call => |c| {
                    if (c.args.len == 0 or c.callee.* != .primary) break;
                    const name = c.callee.primary.name;
                    if (std.mem.eql(u8, name, "@as") and c.args.len == 2) {
                        inner = c.args[1];
                    } else if (std.mem.eql(u8, name, "@constCast") or std.mem.eql(u8, name, "@alignCast")) {
                        inner = c.args[0];
                    } else break;
                },
                else => break,
            }
        }
        switch (inner.*) {
            .unary => |u| if (std.mem.eql(u8, u.operator, "&")) try ctx.markAddrTaken(u.arg),
            .primary => |p| {
                if (p.kind != .identifier and p.kind != .register) return;
                // A parameter holds a pointer value; handing it on means this
                // function keeps a pointer the caller gave it.
                if (ctx.lookup(p.name)) |entry| switch (entry) {
                    .param => |param| try ctx.state.escaping_params.put(param, {}),
                    else => {},
                };
            },
            else => {},
        }
    }

    /// Does the callee keep the pointer passed at `index`? Unknown callees
    /// (builtins, externs, generic instances, variadics) are assumed to keep it.
    fn argEscapes(ctx: *Ctx, c: ast.Call, index: usize) bool {
        const target = ctx.state.call_targets.get(c.callee) orelse return true;
        if (target.generic_instance != null) return true;
        const def = ctx.state.functions.getPtr(target.key) orelse return true;
        if (def.is_variadic or def.node.* != .function_decl) return true;
        const f = &def.node.function_decl;
        if (f.params.* != .params) return true;
        const params = f.params.params.params;
        // A method's receiver occupies params[0] and is not in `args`.
        const offset: usize = if (target.receiver_mode == .none) 0 else 1;
        if (params.len != c.args.len + offset) return true;
        return ctx.state.escaping_params.contains(&params[index + offset]);
    }

    fn walkPlaceRootAssigned(ctx: *Ctx, node: *ast.Node) anyerror!void {
        switch (node.*) {
            .primary => |p| {
                if (p.kind == .identifier or p.kind == .register) ctx.markAssigned(p.name);
            },
            .member => |m| try ctx.walkPlaceRootAssigned(m.object),
            .index => |ix| try ctx.walkPlaceRootAssigned(ix.object),
            else => try ctx.walkExpr(node),
        }
    }

    fn walkAssignTarget(ctx: *Ctx, node: *ast.Node) anyerror!void {
        switch (node.*) {
            .primary => |p| {
                if (p.kind == .identifier or p.kind == .register) ctx.markReassigned(p.name);
            },
            .member => |m| {
                try ctx.walkPlaceRootAssigned(m.object);
                try ctx.walkExpr(m.object);
            },
            .index => |ix| {
                try ctx.walkPlaceRootAssigned(ix.object);
                try ctx.walkExpr(ix.object);
                if (ix.index) |v| try ctx.walkExpr(v);
                if (ix.end) |v| try ctx.walkExpr(v);
            },
            else => try ctx.walkExpr(node),
        }
    }

    fn walkExpr(ctx: *Ctx, node: *ast.Node) anyerror!void {
        switch (node.*) {
            .primary => |p| {
                if (p.kind == .identifier or p.kind == .register) ctx.markRead(p.name);
            },
            .literal => {},
            .binary => |b| {
                // Compile-time type-eq folds — operands are not evaluated.
                if (ctx.state.type_eq_folds.get(b.left) != null) return;
                if (std.mem.eql(u8, b.operator, "|>")) {
                    // `x |> obj.method` — pointer receiver mutates its receiver.
                    const callee: *ast.Node = if (b.right.* == .call) b.right.call.callee else b.right;
                    if (callee.* == .member and callee.member.property.* == .primary) {
                        const m = &callee.member;
                        if (ctx.state.call_targets.get(callee)) |t| {
                            if (t.receiver_mode == .pointer) try ctx.walkPlaceRootAssigned(m.object);
                        }
                    }
                }
                try ctx.walkExpr(b.left);
                try ctx.walkExpr(b.right);
            },
            .unary => |u| {
                if (std.mem.eql(u8, u.operator, "&")) {
                    // Merely taking an address does not escape the frame; the
                    // escape positions are the ones that call `noteEscape`.
                    try ctx.walkPlaceRootAssigned(u.arg);
                } else {
                    try ctx.walkExpr(u.arg);
                }
            },
            .assignment => |asn| {
                try ctx.walkAssignTarget(asn.left);
                try ctx.walkExpr(asn.right);
                // `obj.field = &x` / `arr[i] = &x` publish the pointer into
                // storage that outlives the frame. Assigning to a name that is
                // not local to this body (a module global) escapes for the same
                // reason.
                const stores_into_place = switch (asn.left.*) {
                    .member, .index => true,
                    .primary => |p| (p.kind == .identifier or p.kind == .register) and ctx.lookup(p.name) == null,
                    else => false,
                };
                if (stores_into_place) try ctx.noteEscape(asn.right);
            },
            .call => |c| {
                if (c.inline_asm) |spec| {
                    for (spec.outputs) |output| {
                        if (output.arg_index) |index| try ctx.walkAssignTarget(c.args[index]);
                    }
                    for (spec.inputs) |input| try ctx.walkExpr(c.args[input.arg_index]);
                    return;
                }
                // Compile-time intrinsics don't evaluate operands at runtime.
                if (c.callee.* == .primary) {
                    const name = c.callee.primary.name;
                    if (std.mem.eql(u8, name, "@typeOf") or
                        std.mem.eql(u8, name, "@sizeOf") or
                        std.mem.eql(u8, name, "@nameOf")) return;
                    if (std.mem.eql(u8, name, "@as") and c.args.len == 2) {
                        try ctx.walkExpr(c.args[1]);
                        return;
                    }
                }
                for (c.args, 0..) |arg, ai| {
                    try ctx.walkExpr(arg);
                    // A callee that keeps the pointer (or one we cannot see
                    // into) extends the pointee's lifetime past this frame.
                    if (ctx.argEscapes(c, ai)) try ctx.noteEscape(arg);
                }
                if (c.callee.* == .member) {
                    const m = &c.callee.member;
                    if (m.property.* == .primary) {
                        // Pointer-receiver method mutates its receiver.
                        if (ctx.state.call_targets.get(c.callee)) |t| {
                            if (t.receiver_mode == .pointer) {
                                try ctx.walkPlaceRootAssigned(m.object);
                                try ctx.walkExpr(m.object);
                                return;
                            }
                        }
                    }
                    try ctx.walkExpr(m.object);
                } else {
                    try ctx.walkExpr(c.callee);
                }
            },
            .member => |m| {
                try ctx.walkExpr(m.object);
                if (m.property.* != .primary) {
                    try ctx.walkExpr(m.property);
                }
            },
            .index => |ix| {
                try ctx.walkExpr(ix.object);
                if (ix.index) |v| try ctx.walkExpr(v);
                if (ix.end) |v| try ctx.walkExpr(v);
            },
            .array_literal => |al| {
                for (al.elements) |e| {
                    try ctx.walkExpr(e);
                    try ctx.noteEscape(e);
                }
            },
            .try_expr => |t| try ctx.walkExpr(t.expression),
            .unwrap_expr => |u| try ctx.walkExpr(u.expression),
            .error_expr => |e| {
                for (e.args) |arg| try ctx.walkExpr(arg);
            },
            .struct_init => |si| {
                if (si.type_expr) |te| try ctx.walkExpr(te);
                for (si.fields) |field| {
                    try ctx.walkExpr(field.value);
                    // The aggregate may be stored or returned; a pointer in one
                    // of its fields then outlives this frame.
                    try ctx.noteEscape(field.value);
                }
            },
            .comptime_expr => |ce| try ctx.walkExpr(ce.expr),
            .block, .return_expr, .defer_stmt, .break_expr, .continue_expr,
            .if_expr, .for_expr, .switch_expr => try ctx.walkStmt(node),
            .function_decl => |f| {
                const prev_closure_depth = ctx.closure_base_depth;
                ctx.closure_base_depth = ctx.scopes.items.len;
                defer ctx.closure_base_depth = prev_closure_depth;
                try ctx.pushScope();
                defer ctx.popScope();
                if (f.params.* == .params) {
                    for (f.params.params.params) |*p| {
                        _ = try ctx.state.param_facts.getOrPut(p);
                        try ctx.putParam(p.name, p);
                    }
                }
                try ctx.walkStmt(f.body);
            },
            else => {},
        }
    }

    fn walkStmt(ctx: *Ctx, node: *ast.Node) anyerror!void {
        switch (node.*) {
            .declaration => |d| {
                try ctx.walkExpr(d.value);
                // Insert *after* walking initializer to match runtime scoping.
                // `getOrPut`: repeated fixpoint rounds must not clear flags.
                _ = try ctx.state.binding_facts.getOrPut(node);
                try ctx.putDecl(d.name, node);
            },
            .block => |b| {
                try ctx.pushScope();
                for (b.statements) |s| try ctx.walkStmt(s);
                ctx.popScope();
            },
            .return_expr => |r| {
                if (r.return_value) |v| {
                    try ctx.walkExpr(v);
                    try ctx.noteEscape(v);
                }
            },
            .defer_stmt => |d| try ctx.walkStmt(d.body),
            .break_expr => |b| {
                if (b.value) |v| try ctx.walkExpr(v);
            },
            .continue_expr => |c| {
                if (c.value) |v| try ctx.walkExpr(v);
            },
            .if_expr => |*i| {
                try ctx.walkExpr(i.condition);
                if (i.pipe_value) |pv| {
                    if (pv.* == .primary and
                        (pv.primary.kind == .identifier or pv.primary.kind == .register))
                    {
                        const cap_name = pv.primary.name;
                        try ctx.state.if_capture_facts.put(node, .{});
                        try ctx.pushScope();
                        try ctx.putIfCapture(cap_name, node);
                        try ctx.walkStmt(i.body);
                        ctx.popScope();
                    } else {
                        try ctx.walkExpr(pv);
                        try ctx.walkStmt(i.body);
                    }
                } else {
                    try ctx.walkStmt(i.body);
                }
                if (i.else_body) |e| try ctx.walkStmt(e);
            },
            .for_expr => |*f| {
                try ctx.walkExpr(f.expr);
                try ctx.state.for_capture_facts.put(node, .{ .{}, .{} });
                try ctx.pushScope();
                for (f.captures, 0..) |cap, ci| {
                    if (ci < 2) try ctx.putForCapture(cap.name, node, ci);
                }
                try ctx.walkStmt(f.body);
                ctx.popScope();
            },
            .switch_expr => |sw| {
                try ctx.walkExpr(sw.condition);
                for (sw.prongs) |prong| {
                    for (prong.patterns) |p| try ctx.walkExpr(p);
                    try ctx.walkStmt(prong.body);
                }
            },
            .function_decl => try ctx.walkExpr(node),
            .struct_decl, .enum_decl,
            .error_decl, .type_decl, .extern_decl => {},
            else => try ctx.walkExpr(node),
        }
    }
};
