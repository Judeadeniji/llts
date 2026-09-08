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

    // Skip over function bodies to top-level. OP_JUMP is u16-relative, so chain
    // trampolines every ~60KiB when the function blob exceeds one hop.
    var skip_jump = try emit.emitJump(state, .OP_JUMP);
    var skip_base: usize = 0; // code index of the jump operand being chained from

    var fit = state.functions.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        const def = e.value_ptr;
        if (!reach.isFunctionReachable(name)) continue;

        // Near the u16 jump limit from the current skip hop — land here and hop again.
        const dist = state.chunk.code.items.len -% skip_base;
        if (dist > 0xf000) {
            emit.patchJump(state, skip_jump);
            skip_jump = try emit.emitJump(state, .OP_JUMP);
            skip_base = state.chunk.code.items.len - 2;
        }

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
            if (addr > 0xffff) {
                return compile_errors.compileFailFmt(
                    state,
                    "function '{s}' address {d} exceeds CALL_STATIC u16 limit (forward ref)",
                    .{ name, addr },
                );
            }
            state.chunk.code.items[patch] = @intCast((addr >> 8) & 0xff);
            state.chunk.code.items[patch + 1] = @intCast(addr & 0xff);
        }

        try emit.emitSource(state, def.source_index);
        try stmt.compileFunction(state, &def.node.function_decl, def.node);
    }

    emit.patchJump(state, skip_jump);

    for (doc.statements) |s| {
        if (s.* != .function_decl and s.* != .struct_decl and s.* != .enum_decl and s.* != .error_decl and s.* != .type_decl) {
            if (reach.shouldEmitTopLevel(doc, s)) {
                try stmt.compileStatement(state, s);
            }
        }
    }

    // Language entry: pub zero-arg `main` runs after top-level statements.
    const main_fn = state.chunk.functions.get("main").?;
    if (main_fn.address <= 0xffff) {
        try emit.emitCallStatic(state, @intCast(main_fn.address), 0);
    } else {
        try emit.emitNameGet(state, .OP_GET_FUNCTION, "main");
        try emit.emitOp(state, .OP_CALL);
        try emit.emitByte(state, 0);
    }
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
        } else if (s.* == .type_decl) {
            // Stub so `@struct` fields may mention `*Name` before `@type Name = …`.
            if (state.typedefs.contains(s.type_decl.name)) continue;
            if (state.structs.contains(s.type_decl.name) or state.enums.contains(s.type_decl.name) or
                state.error_sets.contains(s.type_decl.name))
                continue;
            try state.typedefs.put(s.type_decl.name, .{
                .name = s.type_decl.name,
                .underlying = "",
                .distinct = s.type_decl.distinct,
                .stub = true,
            });
        }
    }
}

fn registerFunctions(state: *state_mod.CompilerState, doc: *ast.Document) !void {
    for (doc.statements) |s| try collectFuncs(state, s, null);

    // Widen return types when any return path is `error(...)` or a call that
    // already returns an error-union (fixpoint so `return self.fail()` sees
    // `fail`'s refined type).
    try refineErrorReturns(state);

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

fn widenWithError(state: *state_mod.CompilerState, return_type: *?[]const u8) !void {
    if (return_type.*) |t| {
        if (types.typeAllowsError(t)) return;
        const w = try std.fmt.allocPrint(state.allocator, "{s} | error", .{t});
        try state.owned.append(state.allocator, w);
        return_type.* = w;
    } else {
        return_type.* = "error";
    }
}

fn optionalSliceEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    const aa = a orelse return false;
    const bb = b orelse return false;
    return std.mem.eql(u8, aa, bb);
}

fn calleeReturnType(state: *state_mod.CompilerState, callee: *ast.Node, full_name: []const u8) ?[]const u8 {
    if (callee.* == .primary and callee.primary.kind == .identifier) {
        if (state.functions.get(callee.primary.name)) |def| return def.return_type;
    }
    if (path_mod.tryResolveStaticPath(state, callee) catch null) |p| {
        if (state.functions.get(p)) |def| return def.return_type;
    }
    if (callee.* == .member and callee.member.property.* == .primary) {
        const prop = callee.member.property.primary.name;
        const object = callee.member.object;
        if (object.* == .primary and object.primary.kind == .identifier and std.mem.eql(u8, object.primary.name, "self")) {
            const type_name = selfReceiverTypeName(state, full_name) orelse blk: {
                if (std.mem.lastIndexOf(u8, full_name, "::")) |idx| break :blk full_name[0..idx];
                break :blk null;
            };
            if (type_name) |tn| {
                var buf: [256]u8 = undefined;
                const method_name = std.fmt.bufPrint(&buf, "{s}::{s}", .{ types.unwrapOptionalDisplay(tn), prop }) catch return null;
                if (state.functions.get(method_name)) |def| return def.return_type;
            }
        } else if (types.resolveType(state, object)) |obj_type| {
            var buf: [256]u8 = undefined;
            const method_name = std.fmt.bufPrint(&buf, "{s}::{s}", .{ types.unwrapOptionalDisplay(obj_type), prop }) catch return null;
            if (state.functions.get(method_name)) |def| return def.return_type;
        }
    }
    return null;
}

fn returnValueCarriesError(state: *state_mod.CompilerState, value: *ast.Node, full_name: []const u8) bool {
    switch (value.*) {
        .error_expr => return true,
        .call => |c| {
            if (calleeReturnType(state, c.callee, full_name)) |rt| {
                return types.typeAllowsError(rt);
            }
            return false;
        },
        else => return false,
    }
}

fn scanReturnsForError(state: *state_mod.CompilerState, node: *ast.Node, full_name: []const u8, carries: *bool) void {
    switch (node.*) {
        .return_expr => |r| {
            if (r.return_value) |v| {
                if (returnValueCarriesError(state, v, full_name)) {
                    carries.* = true;
                }
                scanReturnsForError(state, v, full_name, carries);
            }
        },
        // `expr?` propagates error to the caller — same as an error return path.
        .try_expr => |t| {
            carries.* = true;
            scanReturnsForError(state, t.expression, full_name, carries);
        },
        .declaration => |d| scanReturnsForError(state, d.value, full_name, carries),
        .block => |b| for (b.statements) |s| scanReturnsForError(state, s, full_name, carries),
        .if_expr => |i| {
            scanReturnsForError(state, i.condition, full_name, carries);
            scanReturnsForError(state, i.body, full_name, carries);
            if (i.else_body) |e| scanReturnsForError(state, e, full_name, carries);
        },
        .switch_expr => |sw| {
            scanReturnsForError(state, sw.condition, full_name, carries);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| scanReturnsForError(state, pat, full_name, carries);
                scanReturnsForError(state, prong.body, full_name, carries);
            }
        },
        .for_expr => |f| {
            scanReturnsForError(state, f.expr, full_name, carries);
            scanReturnsForError(state, f.body, full_name, carries);
        },
        .call => |c| {
            scanReturnsForError(state, c.callee, full_name, carries);
            for (c.args) |a| scanReturnsForError(state, a, full_name, carries);
        },
        .binary => |b| {
            scanReturnsForError(state, b.left, full_name, carries);
            scanReturnsForError(state, b.right, full_name, carries);
        },
        .unary => |u| scanReturnsForError(state, u.arg, full_name, carries),
        .assignment => |a| {
            scanReturnsForError(state, a.left, full_name, carries);
            scanReturnsForError(state, a.right, full_name, carries);
        },
        .defer_stmt => |d| scanReturnsForError(state, d.body, full_name, carries),
        .break_expr => |br| {
            if (br.value) |v| scanReturnsForError(state, v, full_name, carries);
        },
        else => {},
    }
}

fn refineErrorReturns(state: *state_mod.CompilerState) !void {
    var changed = true;
    var round: u32 = 0;
    while (changed and round < 64) : (round += 1) {
        changed = false;
        var it = state.functions.iterator();
        while (it.next()) |e| {
            const def = e.value_ptr;
            if (def.node.* != .function_decl) continue;
            var carries = false;
            scanReturnsForError(state, def.node.function_decl.body, e.key_ptr.*, &carries);
            if (!carries) continue;
            const before = def.return_type;
            if (def.return_type == null) {
                // Always keep a success arm when unannotated — pure `error` breaks
                // `T = f()?` before the success type is refined.
                const w = try state.allocator.dupe(u8, "unknown | error");
                try state.owned.append(state.allocator, w);
                def.return_type = w;
            } else {
                try widenWithError(state, &def.return_type);
            }
            if (!optionalSliceEql(before, def.return_type)) changed = true;
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
                        if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@new") and c.args.len >= 2) {
                            const arg = c.args[1];
                            // `@new` of a struct yields `*T` (handle), not `T`.
                            if (arg.* == .struct_init) {
                                if (types.resolveStructName(state, arg.struct_init.type_expr)) |sname| {
                                    const ptr_ty = try std.fmt.allocPrint(state.allocator, "*{s}", .{sname});
                                    try state.owned.append(state.allocator, ptr_ty);
                                    return_type.* = ptr_ty;
                                }
                            } else if (arg.* == .primary and arg.primary.kind == .identifier) {
                                if (state.structs.contains(arg.primary.name)) {
                                    const ptr_ty = try std.fmt.allocPrint(state.allocator, "*{s}", .{arg.primary.name});
                                    try state.owned.append(state.allocator, ptr_ty);
                                    return_type.* = ptr_ty;
                                }
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
                        // Prefer the `self` param's type (`self: *Scanner`) over assuming
                        // `full_name` is `Struct::method` — free functions also use `self`.
                        const type_name = selfReceiverTypeName(state, full_name) orelse blk: {
                            if (std.mem.lastIndexOf(u8, full_name, "::")) |idx| break :blk full_name[0..idx];
                            break :blk null;
                        };
                        if (type_name) |tn| {
                            const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ tn, prop });
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

/// Type of a `self` parameter, for `self.method()` call-graph edges.
/// Free functions often take `self: *T`; using `fn_name` alone would treat the
/// module path as the struct (wrong). Falls back to null when unannotated.
fn selfReceiverTypeName(state: *state_mod.CompilerState, full_name: []const u8) ?[]const u8 {
    const def = state.functions.get(full_name) orelse return null;
    if (def.node.* != .function_decl) return null;
    const f = &def.node.function_decl;
    const plist = switch (f.params.*) {
        .params => |p| p.params,
        else => return null,
    };
    for (plist) |param| {
        if (!std.mem.eql(u8, param.name, "self")) continue;
        const ann = param.type_annotation orelse return null;
        const disp = (typecheck.typeAstToDisplay(ann, state) catch return null) orelse return null;
        const bare = types.unwrapOptionalDisplay(disp);
        if (types.lookupStruct(state, bare) != null) return bare;
        return bare;
    }
    return null;
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
