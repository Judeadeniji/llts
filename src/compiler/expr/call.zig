const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const path = @import("path.zig");

const types = @import("../typecheck/from_ast.zig");
const ir = @import("../typecheck/ir.zig");
const intrinsics = @import("../intrinsics.zig");
const generics = @import("../generics.zig");
const scope = @import("../scope.zig");
const compile_errors = @import("../../errors/compile.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileCall(state: *CompilerState, c: *const ast.Call, node: *ast.Node) !void {
    try emit.emitLineIfNeeded(state, c.loc.line, c.loc.column);

    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "print")) {
        const locals_before = state.locals.items.len;
        try emit.emitNameGet(state, .OP_GET_GLOBAL, "print");
        try scope.claimStackTemps(state);
        for (c.args) |arg| {
            try expr.compileExpression(state, arg);
            try scope.claimStackTemps(state);
        }
        try emit.emitOp(state, .OP_CALL);
        try emit.emitByte(state, @intCast(c.args.len));
        scope.notePopN(state, @intCast(c.args.len + 1));
        scope.notePush(state);
        scope.dropLocalEntries(state, state.locals.items.len - locals_before);
        return;
    }
    if (c.callee.* == .primary and std.mem.startsWith(u8, c.callee.primary.name, "@")) {
        const name = c.callee.primary.name;
        if (intrinsics.match(name)) |i| {
            try intrinsics.compile(state, i, node, c);
            return;
        }
        return compile_errors.compileFailFmt(state, "Unknown intrinsic '{s}'", .{name});
    }

    // Generic call: the instance takes only the value arguments.
    if (state.generic_calls.get(node)) |gc| {
        var value_args: std.ArrayList(*ast.Node) = .empty;
        defer value_args.deinit(state.allocator);
        for (generics.params(&gc.template.function_decl), c.args) |p, a| {
            if (!generics.isTypeParam(p)) try value_args.append(state.allocator, a);
        }
        if (try emitNamedCall(state, gc.instance, value_args.items, false, null)) return;
        return compile_errors.compileFailFmt(state, "Internal error: missing generic instance '{s}'", .{gc.instance});
    }

    // Type-function call used as a value (`print(Opt(i64))`): its name.
    if (types.isTypeCall(state, node)) {
        const disp = state.type_call_results.get(node) orelse "unknown";
        var arena = std.heap.ArenaAllocator.init(state.allocator);
        defer arena.deinit();
        const ta = ir.TypeAlloc{ .allocator = arena.allocator() };
        const t = try types.parseDisplayType(state, ta, disp, null);
        try emit.emitString(state, try ir.displayTypeAlloc(arena.allocator(), t));
        return;
    }

    // `T(x)` cast sugar ≡ `@as(T, x)`.
    if (try intrinsics.tryTypeCastCall(state, c)) |type_node| {
        try intrinsics.compileCast(state, type_node, c.args[0]);
        return;
    }

    // Method call: obj.method(args) → Type::method(obj, args...)
    if (c.callee.* == .member) {
        const mem = &c.callee.member;
        if (mem.property.* == .primary) {
            const prop = mem.property.primary.name;
            // `arrayLike.get(i)` → element or null (bounds-safe, Phase 4.4).
            // Structs with a real `get` method are unaffected: their type display
            // does not start with `[`.
            if (std.mem.eql(u8, prop, "get") and c.args.len == 1) {
                if (types.resolveType(state, mem.object)) |disp| {
                    if (arrayElemDisplay(disp) != null) {
                        try expr.compileExpression(state, mem.object);
                        try expr.compileExpression(state, c.args[0]);
                        try emit.emitOp(state, .OP_GET_ARRAY_OR_NULL);
                        return;
                    }
                }
            }
            if (types.resolveType(state, mem.object)) |type_name| {
                if (types.lookupStruct(state, type_name)) |sd| {
                    if (sd.offsets.get(prop) == null) {
                        const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ sd.name, prop });
                        try state.owned.append(state.allocator, method_name);
                        try emitMethodCall(state, method_name, mem.object, c.args);
                        return;
                    }
                }
            }
        }
    }

    if (try resolveCalleeName(state, c.callee)) |name| {
        if (std.mem.indexOf(u8, name, "::") != null and c.callee.* == .member) {
            var buf: [512]u8 = undefined;
            const re_key = std.fmt.bufPrint(&buf, "${s}", .{name}) catch "";
            const re = state.global_types.get(re_key);
            const is_reexport = if (re) |r| std.mem.startsWith(u8, r, "module:") else false;
            if (!state.chunk.exports.contains(name) and !is_reexport) {
                const mem = &c.callee.member;
                const mod_name = if (mem.object.* == .primary) mem.object.primary.name else "Module";
                const prop_name = if (mem.property.* == .primary) mem.property.primary.name else "property";
                                return compile_errors.compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_name, prop_name });
            }
        }
        if (try emitNamedCall(state, name, c.args, false, null)) return;
    }

    const locals_before = state.locals.items.len;
    try expr.compileExpression(state, c.callee);
    try scope.claimStackTemps(state);
    for (c.args) |arg| {
        try expr.compileExpression(state, arg);
        try scope.claimStackTemps(state);
    }
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, @intCast(c.args.len));
    scope.notePopN(state, @intCast(c.args.len + 1));
    scope.notePush(state);
    scope.dropLocalEntries(state, state.locals.items.len - locals_before);
}

/// For an array/slice display type (`[N]T`, `[]T`), return the element display
/// string. Returns null for tuples (`[A, B]`) and non-array types.
fn arrayElemDisplay(disp: []const u8) ?[]const u8 {
    if (disp.len < 2 or disp[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, disp, ']') orelse return null;
    const rest = std.mem.trim(u8, disp[close + 1 ..], " \t");
    if (rest.len == 0) return null;
    return rest;
}

fn emitMethodCall(state: *CompilerState, name: []const u8, self_obj: *ast.Node, args: []*ast.Node) !void {
    // Const-receiver check: pointer-like self (unannotated or *T) can mutate
    // the receiver. By-value self (T) clones; no self has no receiver handle.
    if (scope.constPlaceRoot(state, self_obj)) |recv_name| {
        if (methodSelfIsPointerLike(state, name)) {
            return compile_errors.compileFailFmt(state, "Method might mutate constant '{s}'", .{recv_name});
        }
    }
    const argc: u8 = @intCast(args.len + 1);
    const addr: ?u32 = if (state.functions.getPtr(name)) |def|
        def.address
    else if (state.chunk.functions.get(name)) |fn_info|
        fn_info.address
    else
        return compile_errors.compileFailFmt(state, "Unknown method {s}", .{name});

    // OP_CALL expects [callee, self, ...args]. GET_FUNCTION must precede args.
    // CALL_STATIC only needs [self, ...args] (no callee value).
    const locals_before = state.locals.items.len;
    if (needsDynamicCall(addr)) {
        try emit.emitNameGet(state, .OP_GET_FUNCTION, name);
        try scope.claimStackTemps(state);
    }
    // `self: T` (by value) must receive a shallow copy so field stores do not alias the caller.
    // Unannotated / `self: *T` keep the shared handle.
    if (try methodSelfIsByValue(state, name)) {
        try emit.emitNameGet(state, .OP_GET_GLOBAL, "__cloneBytes");
        try expr.compileExpression(state, self_obj);
        try emit.emitOp(state, .OP_CALL);
        try emit.emitByte(state, 1);
        scope.notePopN(state, 2);
        scope.notePush(state);
    } else {
        try expr.compileExpression(state, self_obj);
    }
    try scope.claimStackTemps(state);
    for (args) |arg| {
        try expr.compileExpression(state, arg);
        try scope.claimStackTemps(state);
    }
    try finishCall(state, addr, argc, state.locals.items.len - locals_before);
}

fn methodSelfIsByValue(state: *CompilerState, name: []const u8) !bool {
    const def = state.functions.get(name) orelse return false;
    if (def.node.* != .function_decl) return false;
    const f = &def.node.function_decl;
    const plist = switch (f.params.*) {
        .params => |p| p.params,
        else => return false,
    };
    if (plist.len == 0) return false;
    const self_param = plist[0];
    if (!std.mem.eql(u8, self_param.name, "self")) return false;
    // Unannotated self defaults to *T.
    const ann = self_param.type_annotation orelse return false;
    const disp = (try types.typeAstToDisplay(ann, state)) orelse return false;
    return disp.len == 0 or disp[0] != '*';
}

/// True when the method's `self` is a pointer (unannotated or *T).
fn methodSelfIsPointerLike(state: *CompilerState, name: []const u8) bool {
    const def = state.functions.get(name) orelse return false;
    if (def.node.* != .function_decl) return false;
    const f = &def.node.function_decl;
    const plist = switch (f.params.*) {
        .params => |p| p.params,
        else => return false,
    };
    if (plist.len == 0) return false;
    const self_param = plist[0];
    if (!std.mem.eql(u8, self_param.name, "self")) return false;
    // Unannotated self defaults to *T → pointer-like.
    const ann = self_param.type_annotation orelse return true;
    const disp = types.typeAstToDisplay(ann, state) catch return true;
    return disp == null or (disp.?.len > 0 and disp.?[0] == '*');
}

fn emitNamedCall(state: *CompilerState, name: []const u8, args: []*ast.Node, _: bool, _: ?*ast.Node) !bool {
    const addr: ?u32 = if (state.functions.getPtr(name)) |def|
        def.address
    else if (state.chunk.functions.get(name)) |fn_info|
        fn_info.address
    else
        return false;

    const argc: u8 = @intCast(args.len);
    // OP_CALL stack: [callee, arg0, ...]. Emit GET_FUNCTION before args when
    // the target is a forward ref or beyond CALL_STATIC's u16 address limit.
    const locals_before = state.locals.items.len;
    if (needsDynamicCall(addr)) {
        try emit.emitNameGet(state, .OP_GET_FUNCTION, name);
        try scope.claimStackTemps(state);
    }
    for (args) |arg| {
        try expr.compileExpression(state, arg);
        try scope.claimStackTemps(state);
    }
    try finishCall(state, addr, argc, state.locals.items.len - locals_before);
    return true;
}

/// True when we must use GET_FUNCTION+CALL instead of CALL_STATIC.
fn needsDynamicCall(addr: ?u32) bool {
    return if (addr) |a| a > 0xffff else true;
}

/// After args (and optional callee) are on the stack: CALL_STATIC or CALL.
/// `claims` is how many anonymous locals this call added for callee/args;
/// they are dropped after the call consumes those stack slots.
fn finishCall(state: *CompilerState, addr: ?u32, argc: u8, claims: usize) !void {
    if (addr) |a| {
        if (a <= 0xffff) {
            try emit.emitCallStatic(state, @intCast(a), argc);
            // CALL_STATIC: pop argc args, push 1 result.
            scope.notePopN(state, argc);
            scope.notePush(state);
            scope.dropLocalEntries(state, claims);
            return;
        }
    }
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, argc);
    // CALL: pop callee+argc, push 1.
    scope.notePopN(state, argc + 1);
    scope.notePush(state);
    scope.dropLocalEntries(state, claims);
}

/// `lhs |> f(a)` compiles as the call `f(lhs, a)`: the left operand is the
/// callee's first argument. Delegating to `compileCall` keeps pipes on the
/// same path as ordinary calls (methods, module exports, generics, cast sugar).
pub fn compilePipe(state: *CompilerState, bin: *const ast.Binary) !void {
    const right = bin.right;
    const callee: *ast.Node = if (right.* == .call) right.call.callee else right;
    const explicit: []const *ast.Node = if (right.* == .call) right.call.args else &.{};
    const args = try state.allocator.alloc(*ast.Node, explicit.len + 1);
    defer state.allocator.free(args);
    args[0] = bin.left;
    @memcpy(args[1..], explicit);
    const c = ast.Call{ .callee = callee, .args = args, .loc = right.loc() };
    try compileCall(state, &c, right);
}

fn resolveCalleeName(state: *CompilerState, callee: *ast.Node) !?[]const u8 {
    if (try path.tryResolveStaticPath(state, callee)) |p| return p;
    if (callee.* == .primary and callee.primary.kind == .identifier) {
        return callee.primary.name;
    }
    if (callee.* == .member) {
        if (try path.tryResolveStaticPath(state, callee)) |p| return p;
    }
    return null;
}
