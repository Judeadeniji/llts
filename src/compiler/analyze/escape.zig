//! Escape analysis for return values.
//!
//! LLTS aggregates are frame-local: a slice or pointer that borrows a local
//! aggregate dies when the function returns. The native emitter lowers a
//! slice view as a raw `(ptr, len)` pair, so returning one that points into
//! the callee's stack/frame storage produces a dangling view (the next call
//! reuses the memory). This pass reports the escape at the `return` site,
//! before either backend lowers the body.
//!
//! Provenance is tracked per lexical binding:
//!   - `storage_frame`: the binding's own storage lives in the current frame
//!     (local fixed arrays and structs). Slicing it yields a frame view.
//!   - `ref_frame`: the binding is a slice whose backing memory is frame-local
//!     (slice literals, slices of locals).
//!
//! Parameters and module globals are caller- or program-owned, so they stay
//! returnable (the documented "pass slices downward" pattern). Values the
//! compiler cannot classify are treated as non-frame, matching the existing
//! escape checker's `.unknown` policy.

const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const ir = @import("../typecheck/ir.zig");
const compile_errors = @import("../../errors/compile.zig");

const CompilerState = state_mod.CompilerState;

const Esc = struct {
    storage_frame: bool = false,
    ref_frame: bool = false,
    ty: ?ir.Type = null,
};

const Ctx = struct {
    state: *CompilerState,
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(std.StringHashMap(Esc)) = .empty,
    visited_fns: std.AutoHashMap(*const ast.Node, void),
    return_ir: ?ir.Type = null,

    fn init(state: *CompilerState) Ctx {
        return .{
            .state = state,
            .allocator = state.allocator,
            .visited_fns = std.AutoHashMap(*const ast.Node, void).init(state.allocator),
        };
    }

    fn deinit(self: *Ctx) void {
        for (self.scopes.items) |*scope| scope.deinit();
        self.scopes.deinit(self.allocator);
        self.visited_fns.deinit();
    }

    fn pushScope(self: *Ctx) !void {
        try self.scopes.append(self.allocator, std.StringHashMap(Esc).init(self.allocator));
    }

    fn popScope(self: *Ctx) void {
        if (self.scopes.items.len == 0) return;
        var scope = self.scopes.pop().?;
        scope.deinit();
    }

    fn put(self: *Ctx, name: []const u8, esc: Esc) !void {
        if (self.scopes.items.len == 0) return;
        try self.scopes.items[self.scopes.items.len - 1].put(name, esc);
    }

    fn lookup(self: *Ctx, name: []const u8) ?Esc {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.get(name)) |esc| return esc;
            if (std.mem.startsWith(u8, name, "$")) {
                if (scope.get(name[1..])) |esc| return esc;
            } else {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "${s}", .{name})) |dollar| {
                    if (scope.get(dollar)) |esc| return esc;
                } else |_| {}
            }
        }
        return null;
    }

    fn scopeKey(scope: *std.StringHashMap(Esc), name: []const u8, buf: *[256]u8) ?[]const u8 {
        if (scope.contains(name)) return name;
        if (std.mem.startsWith(u8, name, "$")) {
            if (scope.contains(name[1..])) return name[1..];
        } else if (std.fmt.bufPrint(buf, "${s}", .{name})) |dollar| {
            if (scope.contains(dollar)) return dollar;
        } else |_| {}
        return null;
    }

    /// Rebind `name` after a declaration, reassignment, or field/index store.
    fn updateBinding(self: *Ctx, name: []const u8, esc: Esc) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            var buf: [256]u8 = undefined;
            if (scopeKey(scope, name, &buf)) |key| {
                scope.getPtr(key).?.* = esc;
                return;
            }
        }
    }

    fn noteAssignment(self: *Ctx, left: *const ast.Node, right: *const ast.Node) !void {
        switch (left.*) {
            .primary => |p| {
                if (p.kind != .identifier and p.kind != .register) return;
                try self.updateValue(p.name, right);
            },
            .member => |m| {
                if (exprRefFrame(self, right)) try self.taintRoot(m.object);
                try self.walkExpr(m.object);
                try self.walkExpr(m.property);
            },
            .index => |ix| {
                if (exprRefFrame(self, right)) try self.taintRoot(ix.object);
                try self.walkExpr(ix.object);
                if (ix.index) |i| try self.walkExpr(i);
                if (ix.end) |e| try self.walkExpr(e);
            },
            else => {},
        }
    }

    fn updateValue(self: *Ctx, name: []const u8, value: *const ast.Node) !void {
        const ty = exprType(self, value);
        try self.put(name, .{
            .storage_frame = isAggregateStorageType(ty),
            .ref_frame = exprRefFrame(self, value),
            .ty = ty,
        });
    }

    fn taintRoot(self: *Ctx, place: *const ast.Node) !void {
        var root = place;
        while (true) {
            switch (root.*) {
                .member => |m| root = m.object,
                .index => |ix| root = ix.object,
                .primary => break,
                else => return,
            }
        }
        if (root.primary.kind != .identifier and root.primary.kind != .register) return;
        if (self.lookup(root.primary.name)) |esc| {
            var updated = esc;
            updated.ref_frame = true;
            self.updateBinding(root.primary.name, updated);
        }
    }

    fn analyzeFunction(
        self: *Ctx,
        f: *const ast.FunctionDecl,
        return_ir: ?ir.Type,
        param_irs: ?[]const ir.Type,
        captures: []const state_mod.ClosureCapture,
    ) !void {
        if (self.visited_fns.contains(f.body)) return;
        try self.visited_fns.put(f.body, {});

        const prev_return = self.return_ir;
        self.return_ir = return_ir;
        defer self.return_ir = prev_return;

        try self.pushScope();
        defer self.popScope();

        if (f.params.* == .params) {
            for (f.params.params.params, 0..) |p, i| {
                const ty: ?ir.Type = if (param_irs) |irs| (if (i < irs.len) irs[i] else null) else null;
                try self.put(p.name, .{
                    .storage_frame = isAggregateStorageType(ty),
                    .ref_frame = false,
                    .ty = ty,
                });
            }
        }
        for (captures) |cap| {
            try self.put(cap.name, .{ .storage_frame = false, .ref_frame = false });
        }

        try self.walkStmt(f.body);
    }

    fn walkStmt(self: *Ctx, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .declaration => |d| {
                try self.walkExpr(d.value);
                try self.updateValue(d.name, d.value);
            },
            .return_expr => |r| {
                if (r.return_value) |v| {
                    try self.walkExpr(v);
                    try self.checkReturn(v);
                }
            },
            .block => |b| {
                try self.pushScope();
                defer self.popScope();
                for (b.statements) |s| try self.walkStmt(s);
            },
            .if_expr => |*i| {
                try self.walkExpr(i.condition);
                try self.walkStmt(i.body);
                if (i.else_body) |e| try self.walkStmt(e);
            },
            .switch_expr => |sw| {
                try self.walkExpr(sw.condition);
                for (sw.prongs) |prong| {
                    for (prong.patterns) |p| try self.walkExpr(p);
                    try self.walkStmt(prong.body);
                }
            },
            .for_expr => |*f| {
                try self.walkExpr(f.expr);
                try self.pushScope();
                defer self.popScope();
                for (f.captures) |cap| {
                    try self.put(cap.name, .{ .storage_frame = false, .ref_frame = false });
                }
                try self.walkStmt(f.body);
            },
            .defer_stmt => |d| try self.walkStmt(d.body),
            .assignment => |a| {
                try self.walkExpr(a.right);
                try self.noteAssignment(a.left, a.right);
            },
            .break_expr => |b| {
                if (b.value) |v| try self.walkExpr(v);
            },
            .continue_expr => |c| {
                if (c.value) |v| try self.walkExpr(v);
            },
            .function_decl => {},
            .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
            else => try self.walkExpr(node),
        }
    }

    fn walkExpr(self: *Ctx, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .binary => |b| {
                try self.walkExpr(b.left);
                try self.walkExpr(b.right);
            },
            .unary => |u| try self.walkExpr(u.arg),
            .call => |c| {
                try self.walkExpr(c.callee);
                for (c.args) |arg| try self.walkExpr(arg);
            },
            .member => |m| {
                try self.walkExpr(m.object);
                try self.walkExpr(m.property);
            },
            .index => |ix| {
                try self.walkExpr(ix.object);
                if (ix.index) |i| try self.walkExpr(i);
                if (ix.end) |e| try self.walkExpr(e);
            },
            .array_literal => |al| {
                for (al.elements) |el| try self.walkExpr(el);
            },
            .struct_init => |si| {
                if (si.type_expr) |t| try self.walkExpr(t);
                for (si.fields) |field| try self.walkExpr(field.value);
            },
            .try_expr => |t| try self.walkExpr(t.expression),
            .unwrap_expr => |u| try self.walkExpr(u.expression),
            .comptime_expr => |ce| try self.walkExpr(ce.expr),
            .error_expr => |e| {
                for (e.args) |arg| try self.walkExpr(arg);
            },
            .function_decl => {},
            .block, .return_expr, .defer_stmt, .break_expr, .continue_expr, .if_expr, .for_expr, .switch_expr => {
                try self.walkStmt(node);
            },
            else => {},
        }
    }

    fn checkReturn(self: *Ctx, value: *const ast.Node) !void {
        if (exprRefFrame(self, value)) {
            return failEscape(self.state, value);
        }
        // Returning a local aggregate where the declared result is a slice
        // coerces it into a frame-backed view (`emitArrayToSlice`).
        if (self.return_ir != null and isSliceLike(self.return_ir.?) and exprStorageFrame(self, value)) {
            return failEscape(self.state, value);
        }
    }
};

pub fn analyze(state: *CompilerState, doc: *ast.Document) !void {
    var ctx = Ctx.init(state);
    defer ctx.deinit();

    try ctx.pushScope();
    defer ctx.popScope();

    var it = state.functions.iterator();
    while (it.next()) |entry| {
        const def = entry.value_ptr;
        if (def.node.* != .function_decl) continue;
        try ctx.analyzeFunction(&def.node.function_decl, def.return_ir, def.param_irs, &.{});
    }

    var cit = state.closures.iterator();
    while (cit.next()) |entry| {
        const cinfo = entry.value_ptr;
        if (cinfo.node.* != .function_decl) continue;
        try ctx.analyzeFunction(&cinfo.node.function_decl, cinfo.ret_ir, cinfo.param_irs, cinfo.captures);
    }

    // Top-level code has no function return, but walking it keeps initializer
    // expressions and nested closure bodies reachable.
    for (doc.statements) |s| {
        switch (s.*) {
            .function_decl, .struct_decl, .enum_decl, .error_decl, .type_decl, .extern_decl => {},
            else => try ctx.walkStmt(s),
        }
    }
}

fn failEscape(state: *CompilerState, value: *const ast.Node) error{CompileError} {
    const loc = value.loc();
    const path = if (loc.path.len > 0) loc.path else state.chunk.file;
    return compile_errors.compileFailAt(
        state,
        path,
        loc.line,
        loc.column,
        "value escapes its frame region; a slice cannot point into a local stack frame — return a copy or write into caller-provided storage",
        .{},
    );
}

fn exprType(ctx: *Ctx, node: *const ast.Node) ?ir.Type {
    return ctx.state.type_ir_of_results.get(@constCast(node));
}

fn isSliceLike(t: ir.Type) bool {
    return switch (ir.peelDefined(t)) {
        .array => |a| a.length == null,
        else => false,
    };
}

fn isAggregateStorageType(t: ?ir.Type) bool {
    const ty = t orelse return false;
    return switch (ir.peelDefined(ty)) {
        .array => |a| a.length != null,
        .struct_ => true,
        else => false,
    };
}

fn typeCarriesRef(state: *CompilerState, t: ir.Type, depth: u8) bool {
    if (depth > 8) return false;
    return switch (ir.peelDefined(t)) {
        .array => |a| a.length == null or typeCarriesRef(state, a.elem.*, depth + 1),
        .ptr => true,
        .struct_ => |name| structCarriesRef(state, name, depth + 1),
        .tuple => |items| blk: {
            for (items) |item| if (typeCarriesRef(state, item, depth + 1)) break :blk true;
            break :blk false;
        },
        .shape => |fields| blk: {
            for (fields) |field| if (typeCarriesRef(state, field.ty, depth + 1)) break :blk true;
            break :blk false;
        },
        .union_ => |arms| blk: {
            for (arms) |arm| if (typeCarriesRef(state, arm, depth + 1)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn structCarriesRef(state: *CompilerState, name: []const u8, depth: u8) bool {
    if (depth > 8) return false;
    const sd = state.structs.get(name) orelse return false;
    if (sd.field_irs.count() > 0) {
        var it = sd.field_irs.iterator();
        while (it.next()) |entry| {
            if (typeCarriesRef(state, entry.value_ptr.*, depth + 1)) return true;
        }
    }
    return false;
}

fn exprRefFrame(ctx: *Ctx, node: *const ast.Node) bool {
    const ty = exprType(ctx, node);
    if (ty != null and !typeCarriesRef(ctx.state, ty.?, 0)) return false;
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) return false;
            const esc = ctx.lookup(p.name) orelse return false;
            return esc.ref_frame;
        },
        .member => |m| {
            const field_ty = exprType(ctx, node);
            if (field_ty != null and !typeCarriesRef(ctx.state, field_ty.?, 0)) return false;
            return exprRefFrame(ctx, m.object);
        },
        .index => |ix| {
            if (ix.is_slice) return exprStorageFrame(ctx, ix.object);
            const elem_ty = exprType(ctx, node);
            if (elem_ty == null or !typeCarriesRef(ctx.state, elem_ty.?, 0)) return false;
            return exprRefFrame(ctx, ix.object);
        },
        .array_literal => |al| {
            if (ty != null and isSliceLike(ty.?)) return true;
            for (al.elements) |el| if (exprRefFrame(ctx, el)) return true;
            return false;
        },
        .struct_init => |si| {
            for (si.fields) |field| if (exprRefFrame(ctx, field.value)) return true;
            return false;
        },
        .comptime_expr => |ce| return exprRefFrame(ctx, ce.expr),
        .try_expr => |t| return exprRefFrame(ctx, t.expression),
        .unwrap_expr => |u| return exprRefFrame(ctx, u.expression),
        .if_expr => |*i| {
            if (branchRefFrame(ctx, i.body)) return true;
            if (i.else_body) |e| return branchRefFrame(ctx, e);
            return false;
        },
        .switch_expr => |sw| {
            for (sw.prongs) |prong| if (branchRefFrame(ctx, prong.body)) return true;
            return false;
        },
        else => return false,
    }
}

fn exprStorageFrame(ctx: *Ctx, node: *const ast.Node) bool {
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) return false;
            const esc = ctx.lookup(p.name) orelse return false;
            return esc.storage_frame or esc.ref_frame;
        },
        .member => |m| {
            const field_ty = exprType(ctx, node) orelse return false;
            const concrete = ir.peelDefined(field_ty);
            if (concrete != .array and concrete != .struct_) return false;
            return exprStorageFrame(ctx, m.object);
        },
        .index => |ix| {
            if (ix.is_slice) return exprStorageFrame(ctx, ix.object);
            const elem_ty = exprType(ctx, node) orelse return false;
            const concrete = ir.peelDefined(elem_ty);
            if (concrete != .array and concrete != .struct_) return false;
            return exprStorageFrame(ctx, ix.object);
        },
        .array_literal => return true,
        .struct_init => return true,
        .comptime_expr => |ce| return exprStorageFrame(ctx, ce.expr),
        else => return false,
    }
}

fn branchRefFrame(ctx: *Ctx, body: *const ast.Node) bool {
    if (body.* != .block) return exprRefFrame(ctx, body);
    const statements = body.block.statements;
    if (statements.len == 0) return false;
    return exprRefFrame(ctx, statements[statements.len - 1]);
}
