//! `@type` / `@alias` declared inside a function body.
//!
//! The type tables are keyed by plain names, so a local type is given a
//! scoped key (`<fn>::Name` for the function body, `<fn>::<n>::Name` for a
//! nested block) and every reference to `Name` inside its block is renamed to
//! it before typecheck. `cleanTypeName` strips everything up to the last `::`,
//! so diagnostics and `@typeOf` still show `Name`.
//!
//! Scope is lexical, like `$` variables: a local type is visible anywhere in
//! the block that declares it (including nested blocks and `@comptime`
//! bodies) and nowhere else. An inner block may shadow an outer or global type.
const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const decl = @import("stmt/decl.zig");
const compile_errors = @import("../errors/compile.zig");

const CompilerState = state_mod.CompilerState;
const Error = error{ CompileError, OutOfMemory, TooManyConstants };

/// Bare local type name → scoped key.
pub const Renames = std.StringHashMap([]const u8);

pub fn hoist(state: *CompilerState, statements: []*ast.Node) !void {
    // Blocks among top-level statements scope their types like function blocks;
    // top-level `@type` / `@alias` themselves stay global.
    var top = Scoped{ .state = state, .owner = "<top>", .params = &.{} };
    defer top.deinit();
    for (statements) |s| {
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
            else => try walk(s, &top),
        }
    }
    try top.finish();

    for (statements) |s| {
        switch (s.*) {
            // Template bodies are hoisted per instance (see `generics.zig`).
            .function_decl => |*f| if (!state.templates.contains(f.name)) try hoistFunction(state, f, f.name),
            .struct_decl => |st| {
                for (st.methods) |m| {
                    if (m.* != .function_decl) continue;
                    const owner = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ st.name, m.function_decl.name });
                    try state.owned.append(state.allocator, owner);
                    try hoistFunction(state, &m.function_decl, owner);
                }
            },
            else => {},
        }
    }
}

pub fn hoistFunction(state: *CompilerState, f: *ast.FunctionDecl, owner: []const u8) !void {
    // With no local type declarations the rename set is always empty and no
    // type/value-clash error can fire, so the full scope walk is a no-op.
    // Skipping it avoids a scope push/pop (two hash maps) per block, which
    // dominated compile time once every imported function is hoisted.
    if (!bodyHasLocalType(f.body)) return;
    var ctx = Scoped{ .state = state, .owner = owner, .params = f.params.params.params };
    defer ctx.deinit();
    try walk(f.body, &ctx);
    try ctx.finish();
}

/// Does `node` contain a `.type_decl` anywhere inside it?
fn bodyHasLocalType(node: ?*ast.Node) bool {
    const n = node orelse return false;
    switch (n.*) {
        .type_decl => return true,
        .function_decl, .struct_decl, .enum_decl, .error_decl, .extern_decl, .literal, .params, .continue_expr => return false,
        .primary, .declaration, .binary, .unary, .assignment, .call, .member, .index, .array_literal, .block, .return_expr, .if_expr, .switch_expr, .for_expr, .break_expr, .defer_stmt, .struct_init, .try_expr, .unwrap_expr, .error_expr, .comptime_expr, .array_type, .pointer_type, .tuple_type, .union_type, .intersection_type, .func_type, .shape_type => {},
    }
    return nodeChildrenHaveLocalType(n);
}

fn nodeChildrenHaveLocalType(n: *ast.Node) bool {
    switch (n.*) {
        .primary => return false,
        .declaration => |d| return bodyHasLocalType(d.type_annotation) or bodyHasLocalType(d.value),
        .binary => |b| return bodyHasLocalType(b.left) or bodyHasLocalType(b.right),
        .unary => |u| return bodyHasLocalType(u.arg),
        .assignment => |a| return bodyHasLocalType(a.left) or bodyHasLocalType(a.right),
        .call => |c| {
            if (bodyHasLocalType(c.callee)) return true;
            for (c.args) |a| if (bodyHasLocalType(a)) return true;
            return false;
        },
        .member => |m| return bodyHasLocalType(m.object),
        .index => |ix| {
            if (bodyHasLocalType(ix.object)) return true;
            if (bodyHasLocalType(ix.index)) return true;
            if (bodyHasLocalType(ix.end)) return true;
            return bodyHasLocalType(ix.type_annotation);
        },
        .array_literal => |a| {
            for (a.elements) |e| if (bodyHasLocalType(e)) return true;
            return false;
        },
        .block => |b| {
            for (b.statements) |s| if (bodyHasLocalType(s)) return true;
            return false;
        },
        .return_expr => |r| return bodyHasLocalType(r.return_value),
        .if_expr => |i| {
            if (bodyHasLocalType(i.condition)) return true;
            if (bodyHasLocalType(i.body)) return true;
            return bodyHasLocalType(i.else_body);
        },
        .switch_expr => |sw| {
            if (bodyHasLocalType(sw.condition)) return true;
            for (sw.prongs) |p| {
                for (p.patterns) |pat| if (bodyHasLocalType(pat)) return true;
                if (bodyHasLocalType(p.body)) return true;
            }
            return false;
        },
        .for_expr => |f| return bodyHasLocalType(f.expr) or bodyHasLocalType(f.body),
        .break_expr => |br| return bodyHasLocalType(br.value),
        .defer_stmt => |d| return bodyHasLocalType(d.body),
        .struct_init => |si| {
            if (bodyHasLocalType(si.type_expr)) return true;
            for (si.fields) |f| if (bodyHasLocalType(f.value)) return true;
            return false;
        },
        .try_expr => |t| return bodyHasLocalType(t.expression),
        .unwrap_expr => |u| return bodyHasLocalType(u.expression),
        .error_expr => |e| {
            for (e.args) |a| if (bodyHasLocalType(a)) return true;
            return false;
        },
        .comptime_expr => |c| return bodyHasLocalType(c.expr),
        .array_type => |a| return bodyHasLocalType(a.elem),
        .pointer_type => |p| return bodyHasLocalType(p.elem),
        .tuple_type => |t| {
            for (t.elems) |e| if (bodyHasLocalType(e)) return true;
            return false;
        },
        .union_type => |u| return bodyHasLocalType(u.left) or bodyHasLocalType(u.right),
        .intersection_type => |ix| return bodyHasLocalType(ix.left) or bodyHasLocalType(ix.right),
        .func_type => |ft| {
            for (ft.params) |p| if (bodyHasLocalType(p)) return true;
            return bodyHasLocalType(ft.return_type);
        },
        .shape_type => |st| {
            for (st.fields) |f| if (bodyHasLocalType(f.type_annotation)) return true;
            return false;
        },
        .type_decl, .function_decl, .struct_decl, .enum_decl, .error_decl, .extern_decl, .literal, .params, .continue_expr => return false,
    }
}

const Scope = struct {
    types: Renames,
    vars: std.StringHashMap(void),
};

/// Lexical scopes for one function body.
const Scoped = struct {
    state: *CompilerState,
    owner: []const u8,
    params: []const ast.Param,
    scopes: std.ArrayList(Scope) = .empty,
    decls: std.ArrayList(*ast.TypeDecl) = .empty,
    blocks_with_types: u32 = 0,

    fn deinit(self: *Scoped) void {
        for (self.scopes.items) |*s| {
            s.types.deinit();
            s.vars.deinit();
        }
        self.scopes.deinit(self.state.allocator);
        self.decls.deinit(self.state.allocator);
    }

    fn finish(self: *Scoped) !void {
        for (self.decls.items) |td| {
            noteLoc(self.state, td.loc);
            try decl.compileTypeDecl(self.state, td);
            try self.state.local_type_decls.put(td, {});
        }
    }

    fn lookup(self: *const Scoped, name: []const u8) ?[]const u8 {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].types.get(name)) |key| return key;
        }
        return null;
    }

    fn varVisible(self: *const Scoped, name: []const u8) bool {
        for (self.params) |p| if (std.mem.eql(u8, p.name, name)) return true;
        for (self.scopes.items) |s| if (s.vars.contains(name)) return true;
        return false;
    }

    fn enter(self: *Scoped, statements: []*ast.Node) Error!void {
        const gpa = self.state.allocator;
        var scope = Scope{ .types = Renames.init(gpa), .vars = std.StringHashMap(void).init(gpa) };
        errdefer {
            scope.types.deinit();
            scope.vars.deinit();
        }
        var prefix: ?[]const u8 = null;
        for (statements) |s| {
            if (s.* != .type_decl) continue;
            const td = &s.type_decl;
            if (scope.types.contains(td.name)) {
                noteLoc(self.state, td.loc);
                if (self.params.len == 0 and std.mem.eql(u8, self.owner, "<top>"))
                    return compile_errors.compileFailFmt(self.state, "Duplicate type '{s}' in this block", .{td.name});
                return compile_errors.compileFailFmt(self.state, "Duplicate type '{s}' in function '{s}'", .{ td.name, cleanName(self.owner) });
            }
            for (self.params) |p| if (std.mem.eql(u8, p.name, td.name)) {
                noteLoc(self.state, p.loc);
                return compile_errors.compileFailFmt(self.state, "'{s}' is declared as both a type and a parameter", .{td.name});
            };
            if (self.varVisible(td.name)) {
                noteLoc(self.state, td.loc);
                return compile_errors.compileFailFmt(self.state, "'{s}' is declared as both a type and a variable", .{td.name});
            }
            if (prefix == null) {
                prefix = if (self.blocks_with_types == 0)
                    self.owner
                else
                    try self.own(try std.fmt.allocPrint(gpa, "{s}::{d}", .{ self.owner, self.blocks_with_types }));
                self.blocks_with_types += 1;
            }
            const key = try self.own(try std.fmt.allocPrint(gpa, "{s}::{s}", .{ prefix.?, td.name }));
            try scope.types.put(td.name, key);
            try self.decls.append(gpa, td);
        }
        try self.scopes.append(gpa, scope);
    }

    fn leave(self: *Scoped) void {
        var s = self.scopes.pop().?;
        s.types.deinit();
        s.vars.deinit();
    }

    fn declareVar(self: *Scoped, name: []const u8, loc: ast.Location) Error!void {
        if (self.lookup(name) != null) {
            noteLoc(self.state, loc);
            return compile_errors.compileFailFmt(self.state, "'{s}' is declared as both a type and a variable", .{name});
        }
        if (self.scopes.items.len > 0) try self.scopes.items[self.scopes.items.len - 1].vars.put(name, {});
    }

    fn own(self: *Scoped, s: []const u8) Error![]const u8 {
        try self.state.owned.append(self.state.allocator, s);
        return s;
    }
};

/// One flat set of renames applied everywhere (type parameters of a generic instance).
const Flat = struct {
    renames: *const Renames,

    fn lookup(self: *const Flat, name: []const u8) ?[]const u8 {
        return self.renames.get(name);
    }
    fn enter(_: *Flat, _: []*ast.Node) Error!void {}
    fn leave(_: *Flat) void {}
    fn declareVar(_: *Flat, _: []const u8, _: ast.Location) Error!void {}
};

fn cleanName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, name, "::")) |i| name[i + 2 ..] else name;
}

fn noteLoc(state: *CompilerState, loc: ast.Location) void {
    if (loc.line > 0) state.diag_line = loc.line;
    if (loc.column > 0) state.diag_column = loc.column;
    if (loc.path.len > 0) state.diag_path = loc.path;
}

/// A variable sharing a local type's name would be renamed along with it.
pub fn checkNoValueClash(state: *CompilerState, node: *ast.Node, renames: *const Renames) Error!void {
    switch (node.*) {
        .declaration => |d| if (renames.contains(d.name)) {
            noteLoc(state, d.loc);
            return compile_errors.compileFailFmt(state, "'{s}' is declared as both a type and a variable", .{d.name});
        },
        .block => |b| for (b.statements) |s| try checkNoValueClash(state, s, renames),
        .if_expr => |i| {
            try checkNoValueClash(state, i.body, renames);
            if (i.else_body) |e| try checkNoValueClash(state, e, renames);
        },
        .for_expr => |f| {
            for (f.captures) |c| if (renames.contains(c.name)) {
                noteLoc(state, f.loc);
                return compile_errors.compileFailFmt(state, "'{s}' is declared as both a type and a variable", .{c.name});
            };
            try checkNoValueClash(state, f.body, renames);
        },
        .switch_expr => |sw| for (sw.prongs) |p| try checkNoValueClash(state, p.body, renames),
        .defer_stmt => |d| try checkNoValueClash(state, d.body, renames),
        .comptime_expr => |c| try checkNoValueClash(state, c.expr, renames),
        else => {},
    }
}

pub fn renameOpt(node: ?*ast.Node, renames: *const Renames) void {
    if (node) |n| rename(n, renames);
}

pub fn rename(node: *ast.Node, renames: *const Renames) void {
    var ctx = Flat{ .renames = renames };
    walk(node, &ctx) catch unreachable;
}

fn walkOpt(node: ?*ast.Node, ctx: anytype) Error!void {
    if (node) |n| try walk(n, ctx);
}

fn walk(node: *ast.Node, ctx: anytype) Error!void {
    switch (node.*) {
        .primary => |*p| if (p.kind == .identifier) {
            if (ctx.lookup(p.name)) |key| p.name = key;
        },
        .type_decl => |*td| {
            try walk(td.type_expr, ctx);
            if (ctx.lookup(td.name)) |key| td.name = key;
        },
        .declaration => |d| {
            try walkOpt(d.type_annotation, ctx);
            try walk(d.value, ctx);
            try ctx.declareVar(d.name, d.loc);
        },
        .binary => |b| {
            try walk(b.left, ctx);
            try walk(b.right, ctx);
        },
        .unary => |u| try walk(u.arg, ctx),
        .assignment => |a| {
            try walk(a.left, ctx);
            try walk(a.right, ctx);
        },
        .call => |c| {
            try walk(c.callee, ctx);
            for (c.args) |a| try walk(a, ctx);
        },
        // Member properties are field / variant names, never types.
        .member => |m| try walk(m.object, ctx),
        .index => |ix| {
            try walk(ix.object, ctx);
            try walkOpt(ix.index, ctx);
            try walkOpt(ix.end, ctx);
            try walkOpt(ix.type_annotation, ctx);
        },
        .array_literal => |a| for (a.elements) |e| try walk(e, ctx),
        .block => |b| {
            try ctx.enter(b.statements);
            defer ctx.leave();
            for (b.statements) |s| try walk(s, ctx);
        },
        .return_expr => |r| try walkOpt(r.return_value, ctx),
        .if_expr => |i| {
            try walk(i.condition, ctx);
            try walk(i.body, ctx);
            try walkOpt(i.else_body, ctx);
        },
        .switch_expr => |sw| {
            try walk(sw.condition, ctx);
            for (sw.prongs) |p| {
                for (p.patterns) |pat| try walk(pat, ctx);
                try walk(p.body, ctx);
            }
        },
        .for_expr => |f| {
            try walk(f.expr, ctx);
            for (f.captures) |c| if (ctx.lookup(c.name) != null) try ctx.declareVar(c.name, f.loc);
            try walk(f.body, ctx);
        },
        .break_expr => |br| try walkOpt(br.value, ctx),
        .defer_stmt => |d| try walk(d.body, ctx),
        .struct_init => |s| {
            try walk(s.type_expr, ctx);
            for (s.fields) |f| try walk(f.value, ctx);
        },
        .try_expr => |t| try walk(t.expression, ctx),
        .unwrap_expr => |u| try walk(u.expression, ctx),
        .error_expr => |e| for (e.args) |a| try walk(a, ctx),
        .comptime_expr => |c| try walk(c.expr, ctx),
        .array_type => |a| try walk(a.elem, ctx),
        .pointer_type => |p| try walk(p.elem, ctx),
        .tuple_type => |t| for (t.elems) |e| try walk(e, ctx),
        .union_type => |u| {
            try walk(u.left, ctx);
            try walk(u.right, ctx);
        },
        .intersection_type => |ix| {
            try walk(ix.left, ctx);
            try walk(ix.right, ctx);
        },
        .func_type => |f| {
            for (f.params) |p| try walk(p, ctx);
            try walkOpt(f.return_type, ctx);
        },
        .shape_type => |s| for (s.fields) |f| try walkOpt(f.type_annotation, ctx),
        .literal, .params, .continue_expr, .function_decl, .struct_decl, .enum_decl, .error_decl, .extern_decl => {},
    }
}
