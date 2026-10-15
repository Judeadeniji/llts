//! `@type` / `@alias` declared inside a function body.
//!
//! The type tables are keyed by plain names, so a local type is given a
//! function-scoped key (`<fn>::Name`) and every reference to `Name` inside that
//! body is renamed to it before typecheck. `cleanTypeName` strips everything up
//! to the last `::`, so diagnostics and `@typeOf` still show `Name`.
//!
//! Scope is the whole function body: a local type is visible anywhere in the
//! function that declares it and nowhere else.
const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const decl = @import("stmt/decl.zig");
const compile_errors = @import("../errors/compile.zig");

const CompilerState = state_mod.CompilerState;
const Error = error{ CompileError, OutOfMemory, TooManyConstants };

/// Bare local type name → function-scoped key.
pub const Renames = std.StringHashMap([]const u8);

pub fn hoist(state: *CompilerState, statements: []*ast.Node) !void {
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
    var decls: std.ArrayList(*ast.TypeDecl) = .empty;
    defer decls.deinit(state.allocator);
    collectTypeDecls(f.body, &decls, state.allocator) catch return error.OutOfMemory;
    if (decls.items.len == 0) return;

    var renames = Renames.init(state.allocator);
    defer renames.deinit();
    for (decls.items) |td| {
        if (renames.contains(td.name)) {
            noteLoc(state, td.loc);
            return compile_errors.compileFailFmt(state, "Duplicate type '{s}' in function '{s}'", .{ td.name, cleanName(owner) });
        }
        const key = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ owner, td.name });
        try state.owned.append(state.allocator, key);
        try renames.put(td.name, key);
    }

    for (f.params.params.params) |p| {
        if (renames.contains(p.name)) {
            noteLoc(state, p.loc);
            return compile_errors.compileFailFmt(state, "'{s}' is declared as both a type and a parameter", .{p.name});
        }
    }
    try checkNoValueClash(state, f.body, &renames);

    rename(f.body, &renames);

    for (decls.items) |td| {
        noteLoc(state, td.loc);
        try decl.compileTypeDecl(state, td);
        try state.local_type_decls.put(td, {});
    }
}

fn cleanName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, name, "::")) |i| name[i + 2 ..] else name;
}

fn noteLoc(state: *CompilerState, loc: ast.Location) void {
    if (loc.line > 0) state.diag_line = loc.line;
    if (loc.column > 0) state.diag_column = loc.column;
    if (loc.path.len > 0) state.diag_path = loc.path;
}

/// Type declarations anywhere in a function body (not in nested functions).
fn collectTypeDecls(node: *ast.Node, out: *std.ArrayList(*ast.TypeDecl), gpa: std.mem.Allocator) !void {
    switch (node.*) {
        .type_decl => |*td| try out.append(gpa, td),
        .block => |b| for (b.statements) |s| try collectTypeDecls(s, out, gpa),
        .if_expr => |i| {
            try collectTypeDecls(i.body, out, gpa);
            if (i.else_body) |e| try collectTypeDecls(e, out, gpa);
        },
        .for_expr => |f| try collectTypeDecls(f.body, out, gpa),
        .switch_expr => |sw| for (sw.prongs) |p| try collectTypeDecls(p.body, out, gpa),
        .defer_stmt => |d| try collectTypeDecls(d.body, out, gpa),
        .comptime_expr => |c| try collectTypeDecls(c.expr, out, gpa),
        else => {},
    }
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
    switch (node.*) {
        .primary => |*p| if (p.kind == .identifier) {
            if (renames.get(p.name)) |key| p.name = key;
        },
        .type_decl => |*td| {
            if (renames.get(td.name)) |key| td.name = key;
            rename(td.type_expr, renames);
        },
        .declaration => |d| {
            renameOpt(d.type_annotation, renames);
            rename(d.value, renames);
        },
        .binary => |b| {
            rename(b.left, renames);
            rename(b.right, renames);
        },
        .unary => |u| rename(u.arg, renames),
        .assignment => |a| {
            rename(a.left, renames);
            rename(a.right, renames);
        },
        .call => |c| {
            rename(c.callee, renames);
            for (c.args) |a| rename(a, renames);
        },
        // Member properties are field / variant names, never types.
        .member => |m| rename(m.object, renames),
        .index => |ix| {
            rename(ix.object, renames);
            renameOpt(ix.index, renames);
            renameOpt(ix.end, renames);
            renameOpt(ix.type_annotation, renames);
        },
        .array_literal => |a| for (a.elements) |e| rename(e, renames),
        .block => |b| for (b.statements) |s| rename(s, renames),
        .return_expr => |r| renameOpt(r.return_value, renames),
        .if_expr => |i| {
            rename(i.condition, renames);
            rename(i.body, renames);
            renameOpt(i.else_body, renames);
        },
        .switch_expr => |sw| {
            rename(sw.condition, renames);
            for (sw.prongs) |p| {
                for (p.patterns) |pat| rename(pat, renames);
                rename(p.body, renames);
            }
        },
        .for_expr => |f| {
            rename(f.expr, renames);
            rename(f.body, renames);
        },
        .break_expr => |br| renameOpt(br.value, renames),
        .defer_stmt => |d| rename(d.body, renames),
        .struct_init => |s| {
            rename(s.type_expr, renames);
            for (s.fields) |f| rename(f.value, renames);
        },
        .try_expr => |t| rename(t.expression, renames),
        .unwrap_expr => |u| rename(u.expression, renames),
        .error_expr => |e| for (e.args) |a| rename(a, renames),
        .comptime_expr => |c| rename(c.expr, renames),
        .array_type => |a| rename(a.elem, renames),
        .pointer_type => |p| rename(p.elem, renames),
        .tuple_type => |t| for (t.elems) |e| rename(e, renames),
        .union_type => |u| {
            rename(u.left, renames);
            rename(u.right, renames);
        },
        .intersection_type => |ix| {
            rename(ix.left, renames);
            rename(ix.right, renames);
        },
        .func_type => |f| {
            for (f.params) |p| rename(p, renames);
            renameOpt(f.return_type, renames);
        },
        .shape_type => |s| for (s.fields) |f| renameOpt(f.type_annotation, renames),
        .literal, .params, .continue_expr, .function_decl, .struct_decl, .enum_decl, .error_decl, .extern_decl => {},
    }
}
