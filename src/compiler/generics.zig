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
const typecheck_root = @import("typecheck/root.zig");
const ir = @import("typecheck/ir.zig");
const layout = @import("layout.zig");
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

/// Integer type names a type function's value parameter may use.
const int_type_names = [_][]const u8{
    "i8", "i16", "i32", "i64", "u1",  "u8",  "u16",
    "u32", "u64", "isize", "usize", "int", "number", "byte",
};

fn isIntAnnotation(n: ?*const ast.Node) bool {
    const t = n orelse return false;
    if (t.* != .primary or t.primary.kind != .identifier) return false;
    for (int_type_names) |name| if (std.mem.eql(u8, t.primary.name, name)) return true;
    return false;
}

/// A compile-time `i64` value parameter on a type function (`Pick(T: type, n: i64)`).
pub fn isValueParam(f: *const ast.FunctionDecl, p: ast.Param) bool {
    return returnsType(f) and !isTypeParam(p);
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

pub fn registerTemplate(state: *CompilerState, node: *ast.Node, struct_name: ?[]const u8) !void {
    const f = &node.function_decl;
    noteLoc(state, f.loc);
    if (struct_name) |sn| {
        // Same mangling as non-template methods, so calls resolve `T::name`.
        if (std.mem.indexOf(u8, f.name, "::") == null) {
            const mangled = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ sn, f.name });
            try state.owned.append(state.allocator, mangled);
            f.name = mangled;
        }
        if (returnsType(f)) {
            return compile_errors.compileFailFmt(state, "Struct method '{s}' cannot be a type function ('type' return)", .{cleanName(f.name)});
        }
    }
    for (params(f)) |p| {
        if (isTypeParam(p) and p.is_rest) {
            noteLoc(state, p.loc);
            return compile_errors.compileFailFmt(state, "Rest parameter '{s}' cannot be of type 'type'", .{p.name});
        }
        if (returnsType(f) and !isTypeParam(p)) {
            noteLoc(state, p.loc);
            if (p.is_rest) {
                return compile_errors.compileFailFmt(state, "Rest parameter '{s}' cannot be a type function value parameter", .{p.name});
            }
            if (!isIntAnnotation(p.type_annotation)) {
                return compile_errors.compileFailFmt(state, "Type function '{s}' value parameter '{s}' must have an integer type", .{ cleanName(f.name), p.name });
            }
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
    const type_fn = returnsType(f);
    for (params(f)) |p| {
        if (!isTypeParam(p)) {
            // A type function's value parameters are compile-time only: the
            // body is evaluated, never emitted, so they are dropped from the copy.
            if (!type_fn) try kept.append(arena, p);
            continue;
        }
        const key = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ prefix, p.name });
        try state.owned.append(state.allocator, key);
        // A method whose type parameter is declared before its receiver leaves
        // the receiver holding the caller's first type argument, so fewer type
        // arguments were collected than the template declares. Report it rather
        // than indexing past the end of the list.
        if (ai >= qualified_args.len) {
            return compile_errors.compileFailFmt(
                state,
                "Generic function '{s}' is missing a type argument for parameter '{s}' (a method's 'self' must lead its parameter list)",
                .{ template.function_decl.name, p.name },
            );
        }
        const underlying = qualified_args[ai];
        ai += 1;
        try state.typedefs.put(key, .{
            .name = key,
            .underlying = underlying,
            .ir = try from_ast.parseDisplayType(state, state.typeAlloc(), underlying, null),
            .distinct = false,
        });
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

// ── generic struct declarations ─────────────────────────────────────────────

/// Validate `@struct Name(T: type, N: i64)` and register it as a template. The
/// declaration itself is never laid out or emitted: each distinct argument
/// list instantiates an entry in `state.structs` (see `instantiateStruct`).
pub fn registerStructTemplate(state: *CompilerState, node: *ast.Node) Error!void {
    const s = &node.struct_decl;
    for (s.params) |p| {
        noteLoc(state, p.loc);
        if (p.is_rest) {
            return compile_errors.compileFailFmt(state, "Struct '{s}' parameter '{s}' cannot be a rest parameter", .{ cleanName(s.name), p.name });
        }
        if (!isTypeParam(p) and !isIntAnnotation(p.type_annotation)) {
            return compile_errors.compileFailFmt(
                state,
                "Struct '{s}' parameter '{s}' must be a 'type' or an integer type: a struct is laid out per instantiation, so a value parameter can only size fields",
                .{ cleanName(s.name), p.name },
            );
        }
    }
    try state.struct_templates.put(s.name, node);
}

/// Instantiate a generic struct for `qualified_args` and return its key
/// (`Name(T)`, module-qualified when the template is). Idempotent: the key is
/// itself the memo, so a second use — or a self-referential field — returns the
/// same instance.
pub fn instantiateStruct(
    state: *CompilerState,
    env: *typecheck_root.Env,
    ta: ir.TypeAlloc,
    template_name: []const u8,
    template: *ast.Node,
    qualified_args: []const []const u8,
    site: ast.Location,
) Error![]const u8 {
    const name = try memoKey(state, template_name, qualified_args);
    if (state.structs.contains(name)) return name;

    const depth = state.instance_depth + 1;
    if (depth > max_depth) {
        return compile_errors.compileFailFmt(state, "Generic struct instantiation too deep (instantiating '{s}')", .{name});
    }

    // Register an empty layout first. A self-referential field (`?*Name(T)`)
    // then resolves to this instance instead of instantiating it forever; the
    // real layout replaces it below.
    try state.structs.put(name, .{
        .name = name,
        .size = 0,
        .offsets = std.StringHashMap(i32).init(state.allocator),
        .types = std.StringHashMap([]const u8).init(state.allocator),
    });

    const arena = state.generic_arena.allocator();
    const copy = clone.cloneNode(arena, template) catch |e| return narrow(e);
    const s = &copy.struct_decl;
    s.name = name;
    s.params = &.{};

    const saved_depth = state.instance_depth;
    state.instance_depth = depth;
    defer state.instance_depth = saved_depth;

    state.instance_counter += 1;
    const prefix = try std.fmt.allocPrint(state.allocator, "{s}${d}", .{ template_name, state.instance_counter });
    try state.owned.append(state.allocator, prefix);
    var renames = local_types.Renames.init(state.allocator);
    defer renames.deinit();
    // Value params (`N: i64`) only size array fields, so they substitute into
    // array lengths instead of becoming type aliases.
    var lengths = std.StringHashMap([]const u8).init(state.allocator);
    defer lengths.deinit();
    for (template.struct_decl.params, qualified_args) |p, arg| {
        if (!isTypeParam(p)) {
            try lengths.put(p.name, arg);
            continue;
        }
        const key = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ prefix, p.name });
        try state.owned.append(state.allocator, key);
        try state.typedefs.put(key, .{
            .name = key,
            .underlying = arg,
            .ir = try from_ast.parseDisplayType(state, state.typeAlloc(), arg, null),
            .distinct = false,
        });
        if (arg.len > 0 and arg[0] == '{') try from_ast.ensureShapeLayoutFromDisplay(state, arg);
        try renames.put(p.name, key);
    }

    for (s.fields) |*f| {
        local_types.renameOpt(f.type_annotation, &renames);
        local_types.substituteLengths(f.type_annotation, &lengths);
    }
    for (s.methods) |m| {
        if (m.* != .function_decl) continue;
        const f = &m.function_decl;
        switch (f.params.*) {
            .params => |*ps| for (ps.params) |*p| {
                local_types.renameOpt(p.type_annotation, &renames);
                local_types.substituteLengths(p.type_annotation, &lengths);
            },
            else => {},
        }
        local_types.renameOpt(f.return_type, &renames);
        local_types.substituteLengths(f.return_type, &lengths);
        local_types.rename(f.body, &renames);
        local_types.substituteLengths(f.body, &lengths);
    }

    try layoutStructInstance(state, env, ta, name, s);

    // Methods: mangled under the instance key, then registered like ordinary
    // methods so typecheck, reachability and the emitter all see them.
    for (s.methods) |m| {
        if (m.* != .function_decl) continue;
        const f = &m.function_decl;
        // Module structs already carry `<module>::<Type>::<method>`; keep only
        // the method and re-prefix with this instance's key.
        const short = if (std.mem.lastIndexOf(u8, f.name, "::")) |i| f.name[i + 2 ..] else f.name;
        const mangled = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ name, short });
        try state.owned.append(state.allocator, mangled);
        f.name = mangled;

        // Signature annotations that were type calls (`Name(T)`) must be
        // resolved while the instance's type params are bound, so the
        // function's recorded return / param types are facts, not `unknown`.
        switch (f.params.*) {
            .params => |*ps| for (ps.params) |*p| {
                const ann = p.type_annotation orelse continue;
                if (!from_ast.typeNodeHasCall(ann)) continue;
                _ = typecheck_root.resolveStructFieldType(state, env, ta, ann) catch |e| return narrow(e);
            },
            else => {},
        }
        if (f.return_type) |rt| {
            if (from_ast.typeNodeHasCall(rt)) {
                _ = typecheck_root.resolveStructFieldType(state, env, ta, rt) catch |e| return narrow(e);
            }
        }
        local_types.hoistFunction(state, f, f.name) catch |e| return narrow(e);
        compiler_root.registerFunction(state, m) catch |e| return narrow(e);
        // A method with its own type params is a template (instantiated on call).
        if (state.templates.contains(f.name)) continue;
        // Lazily checked: typecheck queues an instance method when it sees a
        // call to it, so an unused method that only holds for some element
        // types cannot break the instances that never use it.
        try state.instance_methods.put(f.name, .{ .name = f.name, .depth = depth, .site = site });
    }
    return name;
}

/// Drop instance methods that nothing called. Their bodies were never
/// typechecked, so they must not reach reachability or the emitter — a bare
/// method name in the call index would otherwise pull them in as candidates.
pub fn dropUnusedInstanceMethods(state: *CompilerState) void {
    var it = state.instance_methods.keyIterator();
    while (it.next()) |name| {
        if (state.functions.fetchRemove(name.*)) |kv| {
            var def = kv.value;
            def.calls.deinit();
            def.forward_jumps.deinit(state.allocator);
        }
    }
    state.instance_methods.clearRetainingCapacity();
}

fn layoutStructInstance(
    state: *CompilerState,
    env: *typecheck_root.Env,
    ta: ir.TypeAlloc,
    name: []const u8,
    s: *const ast.StructDecl,
) Error!void {
    var type_map = std.StringHashMap([]const u8).init(state.allocator);
    var field_irs: std.StringHashMapUnmanaged(ir.Type) = .{};
    var specs: std.ArrayList(layout.FieldSpec) = .empty;
    defer specs.deinit(state.allocator);

    for (s.fields) |field| {
        var t: ir.Type = ir.TUnknown;
        if (field.type_annotation) |ann| {
            t = typecheck_root.resolveStructFieldType(state, env, ta, ann) catch |e| return narrow(e);
        }
        const disp = try ir.displayTypeQualifiedAlloc(state.allocator, t);
        try state.owned.append(state.allocator, disp);
        try type_map.put(field.name, disp);
        try field_irs.put(state.allocator, field.name, t);
        try specs.append(state.allocator, .{ .name = field.name, .type_name = disp });
    }

    const laid = try layout.layoutFields(state.allocator, specs.items);
    const def = state.structs.getPtr(name) orelse return error.CompileError;
    def.size = laid.size;
    def.offsets = laid.offsets;
    def.types = type_map;
    def.field_irs = field_irs;
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
