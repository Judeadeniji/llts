//! Type functions (`@func Opt(T: type): type`) and generic functions
//! (`@func max(T: type, a: T, b: T): T`).
//!
//! A function with a `type` param or a `: type` return is a *template*: it is
//! never typechecked or emitted. Each distinct list of type arguments gets an
//! *instance*: a deep copy of the template whose type params are dropped and
//! bound as transparent aliases (`<prefix>::T`, displayed as the argument
//! type), with every reference renamed via `local_types`.
const std = @import("std");
const ast = @import("../ast/root.zig");
const clone = @import("../ast/clone.zig");
const state_mod = @import("state.zig");
const local_types = @import("local_types.zig");
const compile_errors = @import("../errors/compile.zig");
const from_ast = @import("typecheck/from_ast.zig");
const compiler_root = @import("root.zig");

const CompilerState = state_mod.CompilerState;

pub const max_depth = 64;

/// Matches typecheck's error set (instantiation runs during typecheck).
pub const Error = error{ CompileError, InvalidCharacter, OutOfMemory, Overflow };

fn narrow(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCharacter => error.InvalidCharacter,
        error.Overflow => error.Overflow,
        else => error.CompileError,
    };
}

pub fn isTypeAnnotation(n: ?*const ast.Node) bool {
    const t = n orelse return false;
    return t.* == .primary and t.primary.kind == .identifier and std.mem.eql(u8, t.primary.name, "type");
}

pub fn returnsType(f: *const ast.FunctionDecl) bool {
    return isTypeAnnotation(f.return_type);
}

pub fn isTypeParam(p: ast.Param) bool {
    return isTypeAnnotation(p.type_annotation);
}

pub fn params(f: *const ast.FunctionDecl) []ast.Param {
    return f.params.params.params;
}

pub fn isTemplate(f: *const ast.FunctionDecl) bool {
    if (returnsType(f)) return true;
    for (params(f)) |p| if (isTypeParam(p)) return true;
    return false;
}

fn noteLoc(state: *CompilerState, loc: ast.Location) void {
    if (loc.line > 0) state.diag_line = loc.line;
    if (loc.column > 0) state.diag_column = loc.column;
    if (loc.path.len > 0) state.diag_path = loc.path;
}

fn cleanName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, name, "::")) |i| name[i + 2 ..] else name;
}

pub fn registerTemplate(state: *CompilerState, node: *ast.Node, in_struct: bool) !void {
    const f = &node.function_decl;
    noteLoc(state, f.loc);
    if (in_struct) {
        return compile_errors.compileFailFmt(state, "Struct methods cannot take type parameters yet ('{s}')", .{cleanName(f.name)});
    }
    for (params(f)) |p| {
        if (isTypeParam(p) and p.is_rest) {
            noteLoc(state, p.loc);
            return compile_errors.compileFailFmt(state, "Rest parameter '{s}' cannot be of type 'type'", .{p.name});
        }
        if (returnsType(f) and !isTypeParam(p)) {
            noteLoc(state, p.loc);
            return compile_errors.compileFailFmt(state, "Type function '{s}' may only take 'type' parameters ('{s}' is not)", .{ cleanName(f.name), p.name });
        }
    }
    try state.templates.put(f.name, node);
}

/// Memo key: template name plus the *qualified* type arguments, so same-named
/// types from different modules never share an instance.
pub fn memoKey(state: *CompilerState, template_name: []const u8, qualified_args: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.allocator);
    try buf.appendSlice(state.allocator, template_name);
    try buf.append(state.allocator, '(');
    for (qualified_args, 0..) |a, i| {
        if (i > 0) try buf.appendSlice(state.allocator, ", ");
        try buf.appendSlice(state.allocator, a);
    }
    try buf.append(state.allocator, ')');
    const key = try state.allocator.dupe(u8, buf.items);
    try state.owned.append(state.allocator, key);
    return key;
}

/// Readable instance function name (`max(i64)`), suffixed when two distinct
/// argument lists display alike.
fn instanceName(state: *CompilerState, template_name: []const u8, clean_args: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.allocator);
    try buf.appendSlice(state.allocator, template_name);
    try buf.append(state.allocator, '(');
    for (clean_args, 0..) |a, i| {
        if (i > 0) try buf.appendSlice(state.allocator, ", ");
        try buf.appendSlice(state.allocator, a);
    }
    try buf.append(state.allocator, ')');
    var name = try state.allocator.dupe(u8, buf.items);
    var n: u32 = 2;
    while (state.functions.contains(name)) : (n += 1) {
        state.allocator.free(name);
        name = try std.fmt.allocPrint(state.allocator, "{s}#{d}", .{ buf.items, n });
    }
    try state.owned.append(state.allocator, name);
    return name;
}

/// Deep-copy `template`, drop its type params, and bind each to its argument
/// as a transparent alias. Local `@type`/`@alias` in the copy are hoisted.
pub fn bindCopy(state: *CompilerState, template: *ast.Node, name: []const u8, qualified_args: []const []const u8) Error!*ast.Node {
    return bindCopyInner(state, template, name, qualified_args) catch |e| narrow(e);
}

fn bindCopyInner(state: *CompilerState, template: *ast.Node, name: []const u8, qualified_args: []const []const u8) !*ast.Node {
    const arena = state.generic_arena.allocator();
    const copy = try clone.cloneNode(arena, template);
    const f = &copy.function_decl;
    f.name = name;

    // Internal key prefix for this copy's type params and local types; it has
    // no parentheses so stored displays stay parseable. Hidden by `cleanTypeName`.
    state.instance_counter += 1;
    const prefix = try std.fmt.allocPrint(state.allocator, "{s}${d}", .{ template.function_decl.name, state.instance_counter });
    try state.owned.append(state.allocator, prefix);
    var renames = local_types.Renames.init(state.allocator);
    defer renames.deinit();
    var kept: std.ArrayList(ast.Param) = .empty;
    var ai: usize = 0;
    for (params(f)) |p| {
        if (!isTypeParam(p)) {
            try kept.append(arena, p);
            continue;
        }
        const key = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ prefix, p.name });
        try state.owned.append(state.allocator, key);
        const underlying = qualified_args[ai];
        ai += 1;
        try state.typedefs.put(key, .{ .name = key, .underlying = underlying, .distinct = false });
        if (underlying.len > 0 and underlying[0] == '{') try from_ast.ensureShapeLayoutFromDisplay(state, underlying);
        try renames.put(p.name, key);
    }
    f.params.params.params = try kept.toOwnedSlice(arena);

    try local_types.checkNoValueClash(state, f.body, &renames);
    for (params(f)) |*p| local_types.renameOpt(p.type_annotation, &renames);
    local_types.renameOpt(f.return_type, &renames);
    local_types.rename(f.body, &renames);
    try local_types.hoistFunction(state, f, prefix);
    return copy;
}

/// Instance of a generic (value) function for `qualified_args`, created and
/// queued for typecheck on first use.
pub fn instantiateFunction(
    state: *CompilerState,
    template_name: []const u8,
    template: *ast.Node,
    qualified_args: []const []const u8,
    clean_args: []const []const u8,
    site: ast.Location,
) Error![]const u8 {
    const memo = try memoKey(state, template_name, qualified_args);
    if (state.instances.get(memo)) |existing| return existing;

    const depth = state.instance_depth + 1;
    if (depth > max_depth) {
        return compile_errors.compileFailFmt(state, "Generic instantiation too deep (instantiating '{s}')", .{memo});
    }
    const name = try instanceName(state, template_name, clean_args);
    const copy = try bindCopy(state, template, name, qualified_args);
    compiler_root.registerFunction(state, copy) catch |e| return narrow(e);
    try state.instance_fns.put(name, {});
    try state.instances.put(memo, name);
    try state.pending_instances.append(state.allocator, .{ .name = name, .depth = depth, .site = site });
    return name;
}
