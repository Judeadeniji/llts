const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const compile_errors = @import("../errors/compile.zig");

pub const DeclKind = enum {
    variable,
    constant,
    parameter,
    import,
    function,
    struct_type,
    enum_type,
    error_set,
    type_alias,
};

pub const UnusedDecl = struct {
    name: []const u8,
    kind: DeclKind,
    loc: ast.Location,

    pub fn formatMessage(self: UnusedDecl, buf: []u8) []const u8 {
        return switch (self.kind) {
            .variable => std.fmt.bufPrint(buf, "unused variable '{s}'", .{self.name}) catch "unused variable",
            .constant => std.fmt.bufPrint(buf, "unused constant '{s}'", .{self.name}) catch "unused constant",
            .parameter => std.fmt.bufPrint(buf, "unused parameter '{s}'", .{self.name}) catch "unused parameter",
            .import => std.fmt.bufPrint(buf, "unused import '{s}'", .{self.name}) catch "unused import",
            .function => std.fmt.bufPrint(buf, "unused function '{s}'", .{self.name}) catch "unused function",
            .struct_type => std.fmt.bufPrint(buf, "unused struct '{s}'", .{self.name}) catch "unused struct",
            .enum_type => std.fmt.bufPrint(buf, "unused enum '{s}'", .{self.name}) catch "unused enum",
            .error_set => std.fmt.bufPrint(buf, "unused error set '{s}'", .{self.name}) catch "unused error set",
            .type_alias => std.fmt.bufPrint(buf, "unused type '{s}'", .{self.name}) catch "unused type",
        };
    }
};

const TopDecl = struct {
    name: []const u8,
    kind: DeclKind,
    loc: ast.Location,
    is_public: bool,
    node: *ast.Node,
    is_used: bool = false,
};

const LocalVar = struct {
    name: []const u8,
    kind: DeclKind,
    loc: ast.Location,
    is_used: bool = false,
};

const Scope = struct {
    vars: std.ArrayList(LocalVar) = .empty,
};

const Context = struct {
    allocator: std.mem.Allocator,
    doc_path: []const u8,
    top_decls: std.ArrayList(TopDecl) = .empty,
    top_map: std.StringHashMap(usize),
    scopes: std.ArrayList(Scope) = .empty,
    unused_list: std.ArrayList(UnusedDecl) = .empty,
    collect_unused: bool = false,

    fn init(allocator: std.mem.Allocator, doc_path: []const u8) Context {
        return .{
            .allocator = allocator,
            .doc_path = doc_path,
            .top_decls = .empty,
            .top_map = std.StringHashMap(usize).init(allocator),
            .scopes = .empty,
            .unused_list = .empty,
            .collect_unused = false,
        };
    }

    fn deinit(self: *Context) void {
        self.top_decls.deinit(self.allocator);
        self.top_map.deinit();
        for (self.scopes.items) |*s| s.vars.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.unused_list.deinit(self.allocator);
    }

    fn isFromDoc(self: *const Context, loc: ast.Location) bool {
        if (loc.path.len == 0) return true;
        return std.mem.eql(u8, loc.path, self.doc_path);
    }

    fn addTopDecl(self: *Context, name: []const u8, kind: DeclKind, loc: ast.Location, is_pub: bool, node: *ast.Node) !void {
        const idx = self.top_decls.items.len;
        try self.top_decls.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .loc = loc,
            .is_public = is_pub,
            .node = node,
            .is_used = false,
        });
        try self.top_map.put(name, idx);
    }

    fn pushScope(self: *Context) !void {
        try self.scopes.append(self.allocator, .{ .vars = .empty });
    }

    fn popScope(self: *Context) !void {
        if (self.scopes.items.len == 0) return;
        var scope = self.scopes.pop().?;
        if (self.collect_unused) {
            for (scope.vars.items) |v| {
                if (!v.is_used) {
                    try self.unused_list.append(self.allocator, .{
                        .name = v.name,
                        .kind = v.kind,
                        .loc = v.loc,
                    });
                }
            }
        }
        scope.vars.deinit(self.allocator);
    }

    fn addLocal(self: *Context, name: []const u8, kind: DeclKind, loc: ast.Location) !void {
        if (name.len == 0 or name[0] == '_') return;
        if (self.scopes.items.len == 0) return;
        const current = &self.scopes.items[self.scopes.items.len - 1];
        try current.vars.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .loc = loc,
            .is_used = false,
        });
    }

    fn referenceIdentifier(self: *Context, name: []const u8, worklist: ?*std.ArrayList(usize)) void {
        if (name.len == 0) return;
        // 1. Search local scopes from innermost to outermost
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            var j = scope.vars.items.len;
            while (j > 0) {
                j -= 1;
                const v = &scope.vars.items[j];
                if (std.mem.eql(u8, v.name, name)) {
                    v.is_used = true;
                    return; // Local shadows outer/top-level!
                }
            }
        }

        // 2. If not found in any local scope, check top-level declarations
        if (self.top_map.get(name)) |top_idx| {
            const decl = &self.top_decls.items[top_idx];
            if (!decl.is_used) {
                decl.is_used = true;
                if (worklist) |wl| {
                    wl.append(self.allocator, top_idx) catch {};
                }
            }
        }
    }
};

fn walkTypeNode(ctx: *Context, node: *ast.Node, worklist: ?*std.ArrayList(usize)) void {
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) {
                ctx.referenceIdentifier(p.name, worklist);
            }
        },
        .pointer_type => |pt| walkTypeNode(ctx, pt.elem, worklist),
        .array_type => |at| walkTypeNode(ctx, at.elem, worklist),
        .union_type => |ut| {
            walkTypeNode(ctx, ut.left, worklist);
            walkTypeNode(ctx, ut.right, worklist);
        },
        .intersection_type => |it| {
            walkTypeNode(ctx, it.left, worklist);
            walkTypeNode(ctx, it.right, worklist);
        },
        .tuple_type => |tt| {
            for (tt.elems) |el| walkTypeNode(ctx, el, worklist);
        },
        .func_type => |ft| {
            for (ft.params) |p| walkTypeNode(ctx, p, worklist);
            if (ft.return_type) |rt| walkTypeNode(ctx, rt, worklist);
        },
        .shape_type => |st| {
            for (st.fields) |f| {
                if (f.type_annotation) |ta| walkTypeNode(ctx, ta, worklist);
            }
        },
        .member => |m| {
            // E.g. mod.Type: object is the module name
            walkNode(ctx, m.object, worklist);
        },
        else => walkNode(ctx, node, worklist),
    }
}

fn walkNode(ctx: *Context, node: *ast.Node, worklist: ?*std.ArrayList(usize)) void {
    switch (node.*) {
        .literal => {},
        .primary => |p| {
            if (p.kind == .identifier or p.kind == .register) {
                ctx.referenceIdentifier(p.name, worklist);
            }
        },
        .binary => |b| {
            walkNode(ctx, b.left, worklist);
            walkNode(ctx, b.right, worklist);
        },
        .unary => |u| walkNode(ctx, u.arg, worklist),
        .assignment => |a| {
            // Plain assignment `x = expr` does not read `x` if `x` is a primary identifier.
            // Compound assignment (e.g. `x += expr`) reads `x`.
            // Field or index assignment (e.g. `x.f = expr`, `x[0] = expr`) reads `x`.
            if (a.operator.len == 1 and a.operator[0] == '=') {
                if (a.left.* != .primary or (a.left.primary.kind != .identifier and a.left.primary.kind != .register)) {
                    walkNode(ctx, a.left, worklist);
                }
            } else {
                walkNode(ctx, a.left, worklist);
            }
            walkNode(ctx, a.right, worklist);
        },
        .call => |c| {
            walkNode(ctx, c.callee, worklist);
            for (c.args) |arg| {
                // For `@as(Type, val)`, `@sizeOf(Type)`, `@new(a, Type, ...)`
                // the type argument may be an AST node representing a type.
                if (c.callee.* == .primary and std.mem.startsWith(u8, c.callee.primary.name, "@")) {
                    const intr = c.callee.primary.name;
                    if (std.mem.eql(u8, intr, "@as") or std.mem.eql(u8, intr, "@sizeOf") or std.mem.eql(u8, intr, "@new")) {
                        walkTypeNode(ctx, arg, worklist);
                        continue;
                    }
                }
                walkNode(ctx, arg, worklist);
            }
        },
        .member => |m| {
            // In member access `obj.prop`, only `obj` is evaluated as an expression.
            walkNode(ctx, m.object, worklist);
        },
        .index => |ix| {
            walkNode(ctx, ix.object, worklist);
            if (ix.index) |start| walkNode(ctx, start, worklist);
            if (ix.end) |end| walkNode(ctx, end, worklist);
        },
        .array_literal => |al| {
            for (al.elements) |el| walkNode(ctx, el, worklist);
        },
        .struct_init => |si| {
            walkTypeNode(ctx, si.type_expr, worklist);
            for (si.fields) |f| walkNode(ctx, f.value, worklist);
        },
        .try_expr => |te| walkNode(ctx, te.expression, worklist),
        .error_expr => |ee| {
            for (ee.args) |arg| walkNode(ctx, arg, worklist);
        },
        .declaration => |d| {
            if (d.type_annotation) |ta| walkTypeNode(ctx, ta, worklist);
            walkNode(ctx, d.value, worklist);
            // Local variable added to current scope
            ctx.addLocal(d.name, if (d.is_const) .constant else .variable, d.loc) catch {};
        },
        .block => |b| {
            ctx.pushScope() catch return;
            for (b.statements) |s| walkNode(ctx, s, worklist);
            ctx.popScope() catch return;
        },
        .return_expr => |r| {
            if (r.return_value) |rv| walkNode(ctx, rv, worklist);
        },
        .break_expr => |br| {
            if (br.value) |bv| walkNode(ctx, bv, worklist);
        },
        .continue_expr => {},
        .defer_stmt => |d| walkNode(ctx, d.body, worklist),
        .if_expr => |i| {
            walkNode(ctx, i.condition, worklist);
            if (i.pipe_value) |pv| walkNode(ctx, pv, worklist);
            walkNode(ctx, i.body, worklist);
            if (i.else_body) |eb| walkNode(ctx, eb, worklist);
        },
        .switch_expr => |sw| {
            walkNode(ctx, sw.condition, worklist);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| walkNode(ctx, pat, worklist);
                walkNode(ctx, prong.body, worklist);
            }
        },
        .for_expr => |f| {
            walkNode(ctx, f.expr, worklist);
            ctx.pushScope() catch return;
            for (f.captures) |c| {
                ctx.addLocal(c.name, .variable, f.loc) catch {};
            }
            walkNode(ctx, f.body, worklist);
            ctx.popScope() catch return;
        },
        .function_decl => |f| {
            // Function inside another statement or method
            walkFunctionDecl(ctx, f, false, worklist);
        },
        .struct_decl => |s| {
            for (s.fields) |f| {
                if (f.type_annotation) |ta| walkTypeNode(ctx, ta, worklist);
            }
            for (s.methods) |m| {
                if (m.* == .function_decl) {
                    walkFunctionDecl(ctx, m.function_decl, true, worklist);
                }
            }
        },
        .enum_decl => {},
        .error_decl => {},
        .type_decl => |t| walkTypeNode(ctx, t.type_expr, worklist),
        else => {},
    }
}

fn walkFunctionDecl(ctx: *Context, f: ast.FunctionDecl, is_struct_method: bool, worklist: ?*std.ArrayList(usize)) void {
    if (f.return_type) |rt| walkTypeNode(ctx, rt, worklist);

    ctx.pushScope() catch return;

    if (f.params.* == .params) {
        for (f.params.params.params, 0..) |p, idx| {
            if (p.type_annotation) |ta| walkTypeNode(ctx, ta, worklist);
            // Skip `self` receiver in struct methods
            if (is_struct_method and idx == 0 and std.mem.eql(u8, p.name, "self")) continue;
            ctx.addLocal(p.name, .parameter, p.loc) catch {};
        }
    }

    if (f.body.* == .block) {
        for (f.body.block.statements) |s| walkNode(ctx, s, worklist);
    } else {
        walkNode(ctx, f.body, worklist);
    }

    ctx.popScope() catch return;
}

fn lessThan(_: void, a: UnusedDecl, b: UnusedDecl) bool {
    if (a.loc.line != b.loc.line) return a.loc.line < b.loc.line;
    return a.loc.column < b.loc.column;
}

pub fn detect(allocator: std.mem.Allocator, doc: *const ast.Document) ![]UnusedDecl {
    var ctx = Context.init(allocator, doc.path);
    defer ctx.deinit();

    // 1. Collect all top-level declarations that belong to this document
    for (doc.statements) |s| {
        if (!ctx.isFromDoc(s.loc())) continue;
        switch (s.*) {
            .declaration => |d| {
                const is_import = d.value.* == .call and d.value.call.callee.* == .primary and std.mem.eql(u8, d.value.call.callee.primary.name, "@import");
                const kind: DeclKind = if (is_import) .import else if (d.is_const) .constant else .variable;
                try ctx.addTopDecl(d.name, kind, d.loc, d.is_public, s);
            },
            .function_decl => |f| {
                try ctx.addTopDecl(f.name, .function, f.loc, f.is_public, s);
            },
            .struct_decl => |sdecl| {
                try ctx.addTopDecl(sdecl.name, .struct_type, sdecl.loc, sdecl.is_public, s);
            },
            .enum_decl => |e| {
                try ctx.addTopDecl(e.name, .enum_type, e.loc, e.is_public, s);
            },
            .error_decl => |e| {
                try ctx.addTopDecl(e.name, .error_set, e.loc, e.is_public, s);
            },
            .type_decl => |t| {
                try ctx.addTopDecl(t.name, .type_alias, t.loc, t.is_public, s);
            },
            else => {},
        }
    }

    // 2. Mark roots (initially reachable top-level declarations)
    var worklist: std.ArrayList(usize) = .empty;
    defer worklist.deinit(allocator);

    for (ctx.top_decls.items, 0..) |*td, i| {
        if (td.is_public or (td.kind == .function and std.mem.eql(u8, td.name, "main"))) {
            td.is_used = true;
            try worklist.append(allocator, i);
        }
    }

    // Top-level executable statements run at startup and act as roots
    for (doc.statements) |s| {
        if (!ctx.isFromDoc(s.loc())) continue;
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .declaration => continue,
            else => {
                // Top-level executable statement (e.g. print, loop, call)
                walkNode(&ctx, s, &worklist);
            },
        }
    }

    // 3. Process worklist transitively
    while (worklist.items.len > 0) {
        const idx = worklist.pop().?;
        const td = &ctx.top_decls.items[idx];
        switch (td.node.*) {
            .function_decl => |f| {
                walkFunctionDecl(&ctx, f, false, &worklist);
            },
            .struct_decl => |s| {
                for (s.fields) |f| {
                    if (f.type_annotation) |ta| walkTypeNode(&ctx, ta, &worklist);
                }
                for (s.methods) |m| {
                    if (m.* == .function_decl) {
                        walkFunctionDecl(&ctx, m.function_decl, true, &worklist);
                    }
                }
            },
            .type_decl => |t| {
                walkTypeNode(&ctx, t.type_expr, &worklist);
            },
            .declaration => |d| {
                if (d.type_annotation) |ta| walkTypeNode(&ctx, ta, &worklist);
                walkNode(&ctx, d.value, &worklist);
            },
            else => {},
        }
    }

    // 4. Any top-level declaration not marked is_used is unused (if not _ prefixed)
    for (ctx.top_decls.items) |td| {
        if (!td.is_used) {
            if (td.name.len > 0 and td.name[0] == '_') continue;
            try ctx.unused_list.append(allocator, .{
                .name = td.name,
                .kind = td.kind,
                .loc = td.loc,
            });
        }
    }

    // 5. Analyze alive functions and methods for unused parameters and local variables
    ctx.collect_unused = true;
    for (ctx.top_decls.items) |td| {
        if (!td.is_used) continue;
        switch (td.node.*) {
            .function_decl => |f| {
                walkFunctionDecl(&ctx, f, false, null);
            },
            .struct_decl => |s| {
                for (s.methods) |m| {
                    if (m.* == .function_decl) {
                        walkFunctionDecl(&ctx, m.function_decl, true, null);
                    }
                }
            },
            else => {},
        }
    }

    for (doc.statements) |s| {
        if (!ctx.isFromDoc(s.loc())) continue;
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .declaration => continue,
            else => {
                walkNode(&ctx, s, null);
            },
        }
    }

    // Sort results deterministically by source location (line, column)
    std.mem.sort(UnusedDecl, ctx.unused_list.items, {}, lessThan);

    return allocator.dupe(UnusedDecl, ctx.unused_list.items);
}

pub fn detectAndWarn(state: *state_mod.CompilerState, doc: *const ast.Document) void {
    const list = detect(state.allocator, doc) catch return;
    defer state.allocator.free(list);

    for (list) |unused| {
        var msg_buf: [256]u8 = undefined;
        const msg = unused.formatMessage(&msg_buf);
        const file_path = if (unused.loc.path.len > 0) unused.loc.path else doc.path;
        const line = if (unused.loc.line > 0) unused.loc.line else 1;
        const col = if (unused.loc.column > 0) unused.loc.column else 1;
        compile_errors.compileWarnAt(state, file_path, doc.source, line, col, "{s}", .{msg});
    }
}
