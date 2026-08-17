const std = @import("std");
const ast = @import("../ast/root.zig");
const chunk_mod = @import("../bytecode/chunk.zig");
const emit = @import("emit.zig");
const modules = @import("modules.zig");
const scope = @import("scope.zig");
pub const state_mod = @import("state.zig");
const stmt = @import("stmt/root.zig");
const typecheck = @import("typecheck/root.zig");
const path_mod = @import("expr/path.zig");
const reachability = @import("reachability.zig");
const types = @import("typecheck/from_ast.zig");
const compile_errors = @import("../errors/compile.zig");

pub const CompileOptions = struct {
    debug: bool = true,
};

pub const CompileError = error{
    CompileError,
    OutOfMemory,
    TooManyConstants,
};

pub fn analyze(
    allocator: std.mem.Allocator,
    doc: *ast.Document,
    opts: CompileOptions,
) !state_mod.CompilerState {
    var state = try state_mod.create(allocator);
    errdefer {
        state.chunk.deinit();
        state_mod.deinit(&state);
    }

    state.debug = opts.debug;
    state.chunk.file = doc.path;
    state.chunk.source = doc.source;
    state.diag_path = doc.path;
    _ = try state.chunk.addSource(doc.path, doc.source);

    try modules.resolveImports(&state, doc);
    try registerStructNames(&state, doc);
    try registerFunctions(&state, doc);
    try registerModuleDecls(&state, doc);

    for (doc.statements) |s| {
        if (s.* == .struct_decl or s.* == .enum_decl or s.* == .error_decl or s.* == .type_decl) try stmt.compileStatement(&state, s);
    }

    try typecheck.typecheck(&state, doc);
    try requireEntryMain(&state, doc);
    
    return state;
}

pub fn emitBytecode(state: *state_mod.CompilerState, doc: *ast.Document) !chunk_mod.Chunk {
    var reach = try reachability.compute(state, doc);
    defer reach.deinit();

    const main_jump = try emit.emitJump(state, .OP_JUMP);

    var fit = state.functions.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        const def = e.value_ptr;
        if (!reach.isFunctionReachable(name)) continue;

        def.address = @intCast(state.chunk.code.items.len);

        const arity = fnArity(def.node);
        const is_variadic = fnVariadic(def.node);
        const owned_name = try state.chunk.internString(name);
        try state.chunk.functions.put(owned_name, .{
            .name = owned_name,
            .address = def.address.?,
            .arity = arity,
            .is_variadic = is_variadic,
            .source_index = def.source_index,
        });

        for (def.forward_jumps.items) |patch| {
            const addr = def.address.?;
            state.chunk.code.items[patch] = @intCast((addr >> 8) & 0xff);
            state.chunk.code.items[patch + 1] = @intCast(addr & 0xff);
        }

        try emit.emitSource(state, def.source_index);
        try stmt.compileFunction(state, &def.node.function_decl, def.node);
    }

    emit.patchJump(state, main_jump);

    for (doc.statements) |s| {
        if (s.* != .function_decl and s.* != .struct_decl and s.* != .enum_decl and s.* != .error_decl and s.* != .type_decl) {
            if (reach.shouldEmitTopLevel(doc, s)) {
                try stmt.compileStatement(state, s);
            }
        }
    }

    // Language entry: pub zero-arg `main` runs after top-level statements.
    const main_fn = state.chunk.functions.get("main").?;
    try emit.emitCallStatic(state, @intCast(main_fn.address), 0);
    try emit.emitOp(state, .OP_POP); // discard main's return value

    try emit.emitOp(state, .OP_NULL);
    try emit.emitOp(state, .OP_RETURN);

    // Export keys borrow compiler-owned strings; intern them into the chunk before teardown.
    {
        var old_exports = state.chunk.exports;
        state.chunk.exports = std.StringHashMap(void).init(state.allocator);
        var exp_it = old_exports.keyIterator();
        while (exp_it.next()) |name| {
            const owned = try state.chunk.internString(name.*);
            try state.chunk.exports.put(owned, {});
        }
        old_exports.deinit();
    }

    const result = state.chunk;
    // Prevent errdefer from freeing the returned chunk; deinit tables only.
    state.chunk = chunk_mod.Chunk.init(state.allocator);
    return result;
}

pub fn compile(
    allocator: std.mem.Allocator,
    doc: *ast.Document,
    opts: CompileOptions,
) !chunk_mod.Chunk {
    var state = try analyze(allocator, doc, opts);
    defer {
        state.chunk.deinit();
        state_mod.deinit(&state);
    }
    return try emitBytecode(&state, doc);
}

fn requireEntryMain(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    const def = state.functions.getPtr("main") orelse {
        const loc = eofLocation(doc.source);
        return compile_errors.compileFail(
            doc.path,
            doc.source,
            loc.line,
            loc.column,
            "missing entry point 'main'",
        );
    };

    const loc = def.node.loc();
    if (loc.path.len > 0 and !std.mem.eql(u8, loc.path, doc.path)) {
        const eof = eofLocation(doc.source);
        return compile_errors.compileFail(
            doc.path,
            doc.source,
            eof.line,
            eof.column,
            "missing entry point 'main'",
        );
    }

    if (def.node.* != .function_decl or !def.node.function_decl.is_public) {
        return compile_errors.compileFailAt(
            state,
            if (loc.path.len > 0) loc.path else doc.path,
            sourceTextForPath(state, if (loc.path.len > 0) loc.path else doc.path),
            if (loc.line > 0) loc.line else 1,
            if (loc.column > 0) loc.column else 1,
            "entry point 'main' must be pub",
            .{},
        );
    }

    if (fnArity(def.node) != 0 or fnVariadic(def.node)) {
        return compile_errors.compileFailAt(
            state,
            if (loc.path.len > 0) loc.path else doc.path,
            sourceTextForPath(state, if (loc.path.len > 0) loc.path else doc.path),
            if (loc.line > 0) loc.line else 1,
            if (loc.column > 0) loc.column else 1,
            "'main' must take 0 arguments",
            .{},
        );
    }
}

fn eofLocation(source: []const u8) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var column: u32 = 1;
    for (source) |ch| {
        if (ch == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn fnArity(node: *ast.Node) u8 {
    const params = switch (node.*) {
        .function_decl => |f| switch (f.params.*) {
            .params => |p| p.params.len,
            else => 0,
        },
        else => 0,
    };
    return @intCast(params);
}

fn fnVariadic(node: *ast.Node) bool {
    return switch (node.*) {
        .function_decl => |f| switch (f.params.*) {
            .params => |p| p.is_variadic,
            else => false,
        },
        else => false,
    };
}

fn registerStructNames(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    for (doc.statements) |s| {
        if (s.* == .struct_decl) {
            try state.structs.put(s.struct_decl.name, .{
                .name = s.struct_decl.name,
                .size = 0,
                .offsets = std.StringHashMap(i32).init(state.allocator),
                .types = std.StringHashMap([]const u8).init(state.allocator),
            });
        } else if (s.* == .enum_decl) {
            try state.enums.put(s.enum_decl.name, .{
                .name = s.enum_decl.name,
                .variants = std.StringHashMap(i32).init(state.allocator),
            });
        } else if (s.* == .error_decl) {
            try state.error_sets.put(s.error_decl.name, .{
                .name = s.error_decl.name,
                .variants = std.StringHashMap([]const u8).init(state.allocator),
            });
        }
    }
}

fn registerFunctions(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    for (doc.statements) |s| try collectFuncs(state, s, null);

    var visited = std.StringHashMap(void).init(state.allocator);
    defer visited.deinit();
    var stack = std.StringHashMap(void).init(state.allocator);
    defer stack.deinit();

    var it = state.functions.keyIterator();
    while (it.next()) |name| {
        if (!visited.contains(name.*)) {
            _ = try dfsRecursive(state, name.*, &visited, &stack);
        }
    }
}

fn sourceTextForPath(state: *state_mod.CompilerState, path: []const u8) []const u8 {
    for (state.chunk.sources.items) |s| {
        if (std.mem.eql(u8, s.path, path)) return s.text;
    }
    if (std.mem.eql(u8, state.chunk.file, path)) return state.chunk.source;
    for (state.module_docs.items) |md| {
        if (std.mem.eql(u8, md.path, path)) return md.source;
    }
    return state.chunk.source;
}

fn collectFuncs(state: *state_mod.CompilerState, node: *ast.Node, struct_name: ?[]const u8) !void {
    switch (node.*) {
        .function_decl => |*fn_decl| {
            if (struct_name) |sn| {
                if (std.mem.indexOf(u8, fn_decl.name, "::") == null) {
                    const mangled = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ sn, fn_decl.name });
                    try state.owned.append(state.allocator, mangled);
                    fn_decl.name = mangled;
                }
            }

            var calls = std.StringHashMap(void).init(state.allocator);
            var has_loop = false;
            var has_return = false;
            var return_type: ?[]const u8 = null;
            if (fn_decl.return_type) |rt| {
                return_type = typecheck.typeAstToDisplay(rt, state) catch null;
            }
            try analyzeBody(state, fn_decl.body, &calls, &has_loop, &has_return, &return_type, fn_decl.name);
            const loc = node.loc();
            const src_idx: u16 = if (loc.path.len > 0)
                try state.chunk.addSource(loc.path, sourceTextForPath(state, loc.path))
            else
                0;
            try state.functions.put(fn_decl.name, .{
                .node = node,
                .has_loop = has_loop,
                .has_return = has_return,
                .calls = calls,
                .return_type = return_type,
                .source_index = src_idx,
            });
        },
        .struct_decl => |s| {
            for (s.methods) |m| try collectFuncs(state, m, s.name);
        },
        .block => |b| for (b.statements) |s| try collectFuncs(state, s, null),
        .declaration => |d| try collectFuncs(state, d.value, null),
        else => {},
    }
}

fn analyzeBody(
    state: *state_mod.CompilerState,
    node: *ast.Node,
    calls: *std.StringHashMap(void),
    has_loop: *bool,
    has_return: *bool,
    return_type: *?[]const u8,
    full_name: []const u8,
) !void {
    switch (node.*) {
        .for_expr => has_loop.* = true,
        .return_expr => |r| {
            has_return.* = true;
            if (return_type.* == null) {
                if (r.return_value) |v| {
                    if (v.* == .struct_init) return_type.* = types.resolveStructName(state, v.struct_init.type_expr);
                    // `@new(a, Foo{…}|Foo|[N]T)` — return type from value or type arg.
                    if (v.* == .call) {
                        const c = v.call;
                        if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@new") and c.args.len == 2) {
                            const arg = c.args[1];
                            if (arg.* == .struct_init) {
                                return_type.* = types.resolveStructName(state, arg.struct_init.type_expr);
                            } else if (arg.* == .primary and arg.primary.kind == .identifier) {
                                return_type.* = arg.primary.name;
                            }
                        }
                    }
                    if (v.* == .primary and std.mem.eql(u8, v.primary.name, "self")) {
                        if (std.mem.indexOf(u8, full_name, "::")) |idx| {
                            return_type.* = full_name[0..idx];
                        }
                    }
                }
            }
        },
        .call => |c| {
            if (try path_mod.tryResolveStaticPath(state, c.callee)) |name| {
                try calls.put(name, {});
            } else if (c.callee.* == .primary and c.callee.primary.kind == .identifier) {
                try calls.put(c.callee.primary.name, {});
            } else if (c.callee.* == .member) {
                if (c.callee.member.property.* == .primary) {
                    const prop = c.callee.member.property.primary.name;
                    const object = c.callee.member.object;
                    if (object.* == .primary and object.primary.kind == .identifier and std.mem.eql(u8, object.primary.name, "self")) {
                        if (std.mem.indexOf(u8, full_name, "::")) |idx| {
                            const type_name = full_name[0..idx];
                            const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ type_name, prop });
                            try state.owned.append(state.allocator, method_name);
                            try calls.put(method_name, {});
                        } else {
                            try calls.put(prop, {});
                        }
                    } else if (types.resolveType(state, object)) |type_name| {
                        if (types.lookupStruct(state, type_name)) |sd| {
                            if (sd.offsets.get(prop) == null) {
                                const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ types.unwrapOptionalDisplay(type_name), prop });
                                try state.owned.append(state.allocator, method_name);
                                try calls.put(method_name, {});
                            } else {
                                try calls.put(prop, {});
                            }
                        } else {
                            try calls.put(prop, {});
                        }
                    } else if (try path_mod.tryResolveStaticPath(state, c.callee)) |name| {
                        try calls.put(name, {});
                    } else {
                        try calls.put(prop, {});
                    }
                }
            }
            try analyzeBody(state, c.callee, calls, has_loop, has_return, return_type, full_name);
            for (c.args) |a| try analyzeBody(state, a, calls, has_loop, has_return, return_type, full_name);
            return;
        },
        .binary => |b| {
            try analyzeBody(state, b.left, calls, has_loop, has_return, return_type, full_name);
            try analyzeBody(state, b.right, calls, has_loop, has_return, return_type, full_name);
            return;
        },
        .unary => |u| {
            try analyzeBody(state, u.arg, calls, has_loop, has_return, return_type, full_name);
            return;
        },
        .block => |b| {
            for (b.statements) |s| try analyzeBody(state, s, calls, has_loop, has_return, return_type, full_name);
            return;
        },
        .if_expr => |i| {
            try analyzeBody(state, i.condition, calls, has_loop, has_return, return_type, full_name);
            try analyzeBody(state, i.body, calls, has_loop, has_return, return_type, full_name);
            if (i.else_body) |e| try analyzeBody(state, e, calls, has_loop, has_return, return_type, full_name);
            return;
        },
        .switch_expr => |sw| {
            try analyzeBody(state, sw.condition, calls, has_loop, has_return, return_type, full_name);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| try analyzeBody(state, pat, calls, has_loop, has_return, return_type, full_name);
                try analyzeBody(state, prong.body, calls, has_loop, has_return, return_type, full_name);
            }
            return;
        },
        .function_decl => {}, // nested not supported
        else => {},
    }
    // shallow children for remaining
    switch (node.*) {
        .assignment => |a| {
            try analyzeBody(state, a.left, calls, has_loop, has_return, return_type, full_name);
            try analyzeBody(state, a.right, calls, has_loop, has_return, return_type, full_name);
        },
        .for_expr => |f| {
            try analyzeBody(state, f.expr, calls, has_loop, has_return, return_type, full_name);
            try analyzeBody(state, f.body, calls, has_loop, has_return, return_type, full_name);
        },
        .return_expr => |r| {
            if (r.return_value) |v| try analyzeBody(state, v, calls, has_loop, has_return, return_type, full_name);
        },
        .break_expr => |br| {
            if (br.value) |v| try analyzeBody(state, v, calls, has_loop, has_return, return_type, full_name);
        },
        .defer_stmt => |d| try analyzeBody(state, d.body, calls, has_loop, has_return, return_type, full_name),
        else => {},
    }
}

fn dfsRecursive(
    state: *state_mod.CompilerState,
    func_name: []const u8,
    visited: *std.StringHashMap(void),
    stack: *std.StringHashMap(void),
) !bool {
    if (stack.contains(func_name)) return true;
    if (visited.contains(func_name)) return false;
    try visited.put(func_name, {});
    try stack.put(func_name, {});

    const def = state.functions.getPtr(func_name) orelse {
        _ = stack.remove(func_name);
        return false;
    };

    var cit = def.calls.keyIterator();
    while (cit.next()) |call_name| {
        var targets: std.ArrayList([]const u8) = .empty;
        defer targets.deinit(state.allocator);
        if (state.functions.contains(call_name.*)) try targets.append(state.allocator, call_name.*);
        var kit = state.functions.keyIterator();
        while (kit.next()) |k| {
            if (std.mem.endsWith(u8, k.*, call_name.*)) {
                const prefix_len = k.*.len - call_name.*.len;
                if (prefix_len >= 2 and std.mem.eql(u8, k.*[prefix_len - 2 .. prefix_len], "::")) {
                    try targets.append(state.allocator, k.*);
                }
            }
        }
        for (targets.items) |target| {
            if (try dfsRecursive(state, target, visited, stack)) {
                def.is_recursive = true;
                var sit = stack.keyIterator();
                while (sit.next()) |s| {
                    if (state.functions.getPtr(s.*)) |d| d.is_recursive = true;
                }
            }
        }
    }

    _ = stack.remove(func_name);
    return def.is_recursive;
}

fn registerModuleDecls(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    for (doc.statements) |s| {
        if (s.* == .declaration) {
            const decl_node = &s.declaration;
            if (state.global_vars.contains(decl_node.name)) {
                                return @import("../errors/compile.zig").compileFailFmt(state, "Variable '{s}' already declared in this scope", .{decl_node.name});
            }
            try state.global_vars.put(decl_node.name, {});
            if (decl_node.is_const) try state.global_consts.put(decl_node.name, {});
        }
    }
}
