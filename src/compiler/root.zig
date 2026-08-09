const std = @import("std");
const ast = @import("../ast/root.zig");
const chunk_mod = @import("../bytecode/chunk.zig");
const emit = @import("emit.zig");
const modules = @import("modules.zig");
const scope = @import("scope.zig");
const state_mod = @import("state.zig");
const stmt = @import("stmt/root.zig");
const typecheck = @import("typecheck/root.zig");

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

    try modules.resolveImports(&state, doc);
    try registerFunctions(&state, doc);

    for (doc.statements) |s| {
        if (s.* == .struct_decl) try stmt.compileStatement(&state, s);
    }

    try typecheck.typecheck(&state, doc);

    const main_jump = try emit.emitJump(&state, .OP_JUMP);

    var fit = state.functions.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        const def = e.value_ptr;
        def.address = @intCast(state.chunk.code.items.len);

        const arity = fnArity(def.node);
        const is_variadic = fnVariadic(def.node);
        const owned_name = try state.chunk.internString(name);
        try state.chunk.functions.put(owned_name, .{
            .name = owned_name,
            .address = def.address.?,
            .arity = arity,
            .is_variadic = is_variadic,
        });

        for (def.forward_jumps.items) |patch| {
            const addr = def.address.?;
            state.chunk.code.items[patch] = @intCast((addr >> 8) & 0xff);
            state.chunk.code.items[patch + 1] = @intCast(addr & 0xff);
        }

        try stmt.compileFunction(&state, &def.node.function_decl, def.node);
    }

    emit.patchJump(&state, main_jump);
    try scope.beginScope(&state);

    for (doc.statements) |s| {
        if (s.* != .function_decl and s.* != .struct_decl) {
            try stmt.compileStatement(&state, s);
        }
    }

    if (state.functions.get("main")) |main_def| {
        if (main_def.address) |addr| {
            try emit.emitOp(&state, .OP_CALL_STATIC);
            try emit.emitByte(&state, @intCast((addr >> 8) & 0xff));
            try emit.emitByte(&state, @intCast(addr & 0xff));
            try emit.emitByte(&state, 0);
            try emit.emitOp(&state, .OP_POP);
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
            try state.functions.put(fn_decl.name, .{
                .node = node,
                .has_loop = has_loop,
                .has_return = has_return,
                .calls = calls,
                .return_type = return_type,
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
                    if (v.* == .primary and std.mem.eql(u8, v.primary.name, "self")) {
                        if (std.mem.indexOf(u8, full_name, "::")) |idx| {
                            return_type.* = full_name[0..idx];
                        }
                    }
                }
            }
        },
        .call => |c| {
            if (c.callee.* == .primary and c.callee.primary.kind == .identifier) {
                try calls.put(c.callee.primary.name, {});
            } else if (c.callee.* == .member) {
                if (c.callee.member.property.* == .primary) {
                    try calls.put(c.callee.member.property.primary.name, {});
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
            const suffix = try std.fmt.allocPrint(state.allocator, "::{s}", .{call_name.*});
            defer state.allocator.free(suffix);
            if (std.mem.endsWith(u8, k.*, suffix)) try targets.append(state.allocator, k.*);
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
