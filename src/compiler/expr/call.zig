const std = @import("std");
const ast = @import("../../ast/root.zig");
const emit = @import("../emit.zig");
const state_mod = @import("../state.zig");
const expr = @import("root.zig");
const path = @import("path.zig");

const types = @import("../typecheck/from_ast.zig");
const aggregate = @import("aggregate.zig");

const CompilerState = state_mod.CompilerState;

pub fn compileCall(state: *CompilerState, c: *const ast.Call, node: *ast.Node) !void {
    try emit.emitLineIfNeeded(state, c.loc.line, c.loc.column);

    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "print")) {
        try emit.emitNameGet(state, .OP_GET_GLOBAL, "print");
        for (c.args) |arg| try expr.compileExpression(state, arg);
        try emit.emitOp(state, .OP_CALL);
        try emit.emitByte(state, @intCast(c.args.len));
        return;
    }
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@isError")) {
        if (c.args.len != 1) {
            return @import("../../errors/compile.zig").compileFailFmt(state, "@isError expects exactly 1 argument", .{});
        }
        try expr.compileExpression(state, c.args[0]);
        try emit.emitOp(state, .OP_IS_ERROR);
        return;
    }
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@typeOf")) {
        if (c.args.len != 1) {
                        return @import("../../errors/compile.zig").compileFailFmt(state, "@typeOf expects exactly 1 argument", .{});
        }
        // Prefer typecheck-filled result; fall back to resolveType for emit-only paths.
        const disp = state.type_of_results.get(node) orelse
            types.resolveType(state, c.args[0]) orelse "unknown";
        // Compile arg for side effects then discard.
        try expr.compileExpression(state, c.args[0]);
        try emit.emitOp(state, .OP_POP);
        try emit.emitString(state, disp);
        return;
    }
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@sizeOf")) {
        if (c.args.len != 1) {
            return @import("../../errors/compile.zig").compileFailFmt(state, "@sizeOf expects exactly 1 argument", .{});
        }
        
        var static_type: ?[]const u8 = null;
        if (c.args[0].* == .primary and c.args[0].primary.kind == .identifier) {
            static_type = c.args[0].primary.name;
        } else if (try path.tryResolveStaticPath(state, c.args[0])) |p| {
            static_type = p;
        }
        
        if (static_type) |name| {
            var is_type = false;
            var size: i32 = 0;
            if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float")) {
                is_type = true; size = 8;
            } else if (std.mem.eql(u8, name, "bool")) {
                is_type = true; size = 1;
            } else if (std.mem.eql(u8, name, "null")) {
                is_type = true; size = 0;
            } else if (std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "[]byte")) {
                is_type = true; size = 16;
            } else if (state.structs.get(name)) |sd| {
                is_type = true; size = sd.size * 16;
            }
            if (is_type) {
                try emit.emitConstant(state, .{ .int = size });
                return;
            }
        }
        
        if (types.resolveType(state, c.args[0])) |type_name| {
            if (state.structs.get(type_name)) |sd| {
                try expr.compileExpression(state, c.args[0]);
                try emit.emitOp(state, .OP_POP);
                try emit.emitConstant(state, .{ .int = sd.size * 16 });
                return;
            }
        }

        try expr.compileExpression(state, c.args[0]);
        try emit.emitOp(state, .OP_SIZEOF);
        return;
    }
    // `@new(allocator, Foo{…}|[…])` — compiler intrinsic (Go make-style).
    // Allocator is a *library* value (std.mem.Arena); `@` means the compiler
    // sees the alloc and colors the result as Pass (may escape the frame).
    if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@new")) {
        try aggregate.compileNew(state, c);
        return;
    }

    // Method call: obj.method(args) → Type::method(obj, args...)
    if (c.callee.* == .member) {
        const mem = &c.callee.member;
        if (mem.property.* == .primary) {
            const prop = mem.property.primary.name;
            if (types.resolveType(state, mem.object)) |type_name| {
                if (state.structs.get(type_name)) |sd| {
                    if (sd.offsets.get(prop) == null) {
                        const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ type_name, prop });
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
                                return @import("../../errors/compile.zig").compileFailFmt(state, "'{s}' has no export '{s}'", .{ mod_name, prop_name });
            }
        }
        if (try emitNamedCall(state, name, c.args, false, null)) return;
    }

    try expr.compileExpression(state, c.callee);
    for (c.args) |arg| try expr.compileExpression(state, arg);
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, @intCast(c.args.len));
}

fn emitMethodCall(state: *CompilerState, name: []const u8, self_obj: *ast.Node, args: []*ast.Node) !void {
    try expr.compileExpression(state, self_obj);
    for (args) |arg| try expr.compileExpression(state, arg);
    const argc: u8 = @intCast(args.len + 1);
    if (state.functions.getPtr(name)) |def| {
        if (def.address) |addr| {
            try emit.emitCallStatic(state, @intCast(addr), argc);
        } else {
            try emit.emitOp(state, .OP_CALL_STATIC);
            const patch = state.chunk.code.items.len;
            try emit.emitByte(state, 0xff);
            try emit.emitByte(state, 0xff);
            try emit.emitByte(state, argc);
            try def.forward_jumps.append(state.allocator, patch);
        }
        return;
    }
    if (state.chunk.functions.get(name)) |fn_info| {
        try emit.emitCallStatic(state, @intCast(fn_info.address), argc);
        return;
    }
        return @import("../../errors/compile.zig").compileFailFmt(state, "Unknown method {s}", .{name});
}

fn emitNamedCall(state: *CompilerState, name: []const u8, args: []*ast.Node, _: bool, _: ?*ast.Node) !bool {
    if (state.functions.getPtr(name)) |def| {
        for (args) |arg| try expr.compileExpression(state, arg);
        if (def.address) |addr| {
            try emit.emitCallStatic(state, @intCast(addr), @intCast(args.len));
        } else {
            try emit.emitOp(state, .OP_CALL_STATIC);
            const patch = state.chunk.code.items.len;
            try emit.emitByte(state, 0xff);
            try emit.emitByte(state, 0xff);
            try emit.emitByte(state, @intCast(args.len));
            try def.forward_jumps.append(state.allocator, patch);
        }
        return true;
    }
    if (state.chunk.functions.get(name)) |fn_info| {
        for (args) |arg| try expr.compileExpression(state, arg);
        try emit.emitCallStatic(state, @intCast(fn_info.address), @intCast(args.len));
        return true;
    }
    return false;
}

pub fn compilePipe(state: *CompilerState, bin: *const ast.Binary) !void {
    if (bin.right.* == .call) {
        const c = &bin.right.call;
        // Build a synthetic call: callee(left, ...args)
        if (try resolveCalleeName(state, c.callee)) |name| {
            if (state.functions.getPtr(name)) |def| {
                try expr.compileExpression(state, bin.left);
                for (c.args) |arg| try expr.compileExpression(state, arg);
                const argc: u8 = @intCast(c.args.len + 1);
                if (def.address) |addr| {
                    try emit.emitCallStatic(state, @intCast(addr), argc);
                } else {
                    try emit.emitOp(state, .OP_CALL_STATIC);
                    const patch = state.chunk.code.items.len;
                    try emit.emitByte(state, 0xff);
                    try emit.emitByte(state, 0xff);
                    try emit.emitByte(state, argc);
                    try def.forward_jumps.append(state.allocator, patch);
                }
                return;
            }
        }
        try expr.compileExpression(state, c.callee);
        try expr.compileExpression(state, bin.left);
        for (c.args) |arg| try expr.compileExpression(state, arg);
        try emit.emitOp(state, .OP_CALL);
        try emit.emitByte(state, @intCast(c.args.len + 1));
        return;
    }

    try expr.compileExpression(state, bin.right);
    try expr.compileExpression(state, bin.left);
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
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
