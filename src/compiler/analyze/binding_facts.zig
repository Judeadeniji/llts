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

    try ctx.pushScope();
    if (f.params.* == .params) {
        for (f.params.params.params) |*p| {
            try state.param_facts.put(p, .{});
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

    /// Record that the place rooted at `node` is address-taken (`&place`).
    ///
    /// Consumers rely on this: the bytecode backend allocates such a local's
    /// aggregate literal below the immortal floor, and the native emitter boxes
    /// it in immortal storage, so a pointer stored into a field or returned from
    /// the function cannot dangle once the frame is rewound. Keyed by the
    /// declaration's initializer node — the shape both backends see.
    fn markAddrTaken(ctx: *Ctx, node: *ast.Node) anyerror!void {
        var root = node;
        while (true) {
            switch (root.*) {
                .member => |m| root = m.object,
                .index => |ix| root = ix.object,
                .primary => break,
                else => return,
            }
        }
        if (root.primary.kind != .identifier and root.primary.kind != .register) return;
        const name = root.primary.name;
        var i = ctx.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (ctx.scopes.items[i].get(name)) |entry| {
                switch (entry) {
                    .decl => |decl_node| try ctx.state.addr_taken_decls.put(decl_node.declaration.value, {}),
                    else => {},
                }
                return;
            }
        }
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
                    try ctx.markAddrTaken(u.arg);
                    try ctx.walkPlaceRootAssigned(u.arg);
                } else {
                    try ctx.walkExpr(u.arg);
                }
            },
            .assignment => |asn| {
                try ctx.walkAssignTarget(asn.left);
                try ctx.walkExpr(asn.right);
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
                for (c.args) |arg| try ctx.walkExpr(arg);
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
                for (al.elements) |e| try ctx.walkExpr(e);
            },
            .try_expr => |t| try ctx.walkExpr(t.expression),
            .unwrap_expr => |u| try ctx.walkExpr(u.expression),
            .error_expr => |e| {
                for (e.args) |arg| try ctx.walkExpr(arg);
            },
            .struct_init => |si| {
                if (si.type_expr) |te| try ctx.walkExpr(te);
                for (si.fields) |field| try ctx.walkExpr(field.value);
            },
            .comptime_expr => |ce| try ctx.walkExpr(ce.expr),
            .block, .return_expr, .defer_stmt, .break_expr, .continue_expr,
            .if_expr, .for_expr, .switch_expr => try ctx.walkStmt(node),
            else => {},
        }
    }

    fn walkStmt(ctx: *Ctx, node: *ast.Node) anyerror!void {
        switch (node.*) {
            .declaration => |d| {
                try ctx.walkExpr(d.value);
                // Insert *after* walking initializer to match runtime scoping.
                try ctx.state.binding_facts.put(node, .{});
                try ctx.putDecl(d.name, node);
            },
            .block => |b| {
                try ctx.pushScope();
                for (b.statements) |s| try ctx.walkStmt(s);
                ctx.popScope();
            },
            .return_expr => |r| {
                if (r.return_value) |v| try ctx.walkExpr(v);
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
            .function_decl, .struct_decl, .enum_decl,
            .error_decl, .type_decl, .extern_decl => {},
            else => try ctx.walkExpr(node),
        }
    }
};
