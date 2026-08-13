const std = @import("std");
const ast = @import("../ast/root.zig");
const chunk_mod = @import("../bytecode/chunk.zig");
const emit = @import("emit.zig");
const modules = @import("modules.zig");
const scope = @import("scope.zig");
const state_mod = @import("state.zig");
const stmt = @import("stmt/root.zig");
const typecheck = @import("typecheck/root.zig");
const path_mod = @import("expr/path.zig");
const reachability = @import("reachability.zig");
const types = @import("typecheck/from_ast.zig");

pub const CompileOptions = struct {
    debug: bool = true,
};

pub const CompileError = error{
    CompileError,
    OutOfMemory,
    TooManyConstants,
};

pub fn compile(
    allocator: std.mem.Allocator,
    doc: *ast.Document,
    opts: CompileOptions,
) !chunk_mod.Chunk {
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
        if (s.* == .struct_decl or s.* == .enum_decl) try stmt.compileStatement(&state, s);
    }

    try typecheck.typecheck(&state, doc);

    var reach = try reachability.compute(&state, doc);
    defer reach.deinit();

    const main_jump = try emit.emitJump(&state, .OP_JUMP);

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

        try emit.emitSource(&state, def.source_index);
        try stmt.compileFunction(&state, &def.node.function_decl, def.node);
    }

    emit.patchJump(&state, main_jump);

    for (doc.statements) |s| {
        if (s.* != .function_decl and s.* != .struct_decl and s.* != .enum_decl) {
            if (reach.shouldEmitTopLevel(doc, s)) {
                try stmt.compileStatement(&state, s);
            }
        }
    }

    // Language entry: zero-arg `main` runs after top-level statements (tests/10_main).
    if (state.chunk.functions.get("main")) |main_fn| {
        if (main_fn.arity == 0) {
            try emit.emitCallStatic(&state, @intCast(main_fn.address), 0);
            try emit.emitOp(&state, .OP_POP); // discard main's return value
        }
    }

    try emit.emitOp(&state, .OP_NULL);
    try emit.emitOp(&state, .OP_RETURN);

    const result = state.chunk;
    // Prevent errdefer from freeing the returned chunk; deinit tables only.
    state.chunk = chunk_mod.Chunk.init(allocator);
    state.chunk.deinit();
    state_mod.deinit(&state);
    return result;
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
        }
    }
}

fn registerFunctions(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    for (doc.statements) |s| try collectFuncs(state, s);

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

fn collectFuncs(state: *state_mod.CompilerState, node: *ast.Node) !void {
    switch (node.*) {
        .function_decl => |*fn_decl| {
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
            for (s.methods) |m| try collectFuncs(state, m);
        },
        .block => |b| for (b.statements) |s| try collectFuncs(state, s),
        .declaration => |d| try collectFuncs(state, d.value),
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
                    if (v.* == .struct_init) return_type.* = v.struct_init.name;
                    // `@new(a, Foo{…}|Foo|[N]T)` — return type from value or type arg.
                    if (v.* == .call) {
                        const c = v.call;
                        if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@new") and c.args.len == 2) {
                            const arg = c.args[1];
                            if (arg.* == .struct_init) {
                                return_type.* = arg.struct_init.name;
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
                        if (state.structs.get(type_name)) |sd| {
                            if (sd.offsets.get(prop) == null) {
                                const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ type_name, prop });
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
            if (f.condition) |c| try analyzeBody(state, c, calls, has_loop, has_return, return_type, full_name);
            if (f.range_start) |s| try analyzeBody(state, s, calls, has_loop, has_return, return_type, full_name);
            if (f.range_end) |e| try analyzeBody(state, e, calls, has_loop, has_return, return_type, full_name);
            if (f.iterable) |it| try analyzeBody(state, it, calls, has_loop, has_return, return_type, full_name);
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
