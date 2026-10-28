const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const state_mod = @import("../../state.zig");
const from_ast = @import("../../typecheck/from_ast.zig");
const root_mod = @import("root.zig");
const prescan_mod = @import("prescan.zig");
const stmt_mod = @import("stmt.zig");
const expr_mod = @import("expr.zig");
const Emitter = root_mod.Emitter;
const ValType = root_mod.ValType;
const Binding = root_mod.Binding;
const Global = root_mod.Global;

pub fn collectGlobals(self: *Emitter) !void {
    const a = self.arena.allocator();
    for (self.doc.statements) |s| {
        if (s.* != .declaration) continue;
        const d = &s.declaration;
        if (root_mod.isImportDecl(d)) continue;
        if (self.reach) |*r| {
            if (!r.shouldEmitTopLevel(self.doc, s)) continue;
        }
        if (self.globals.contains(d.name)) continue;
        const display = self.displayForDeclValue(d) catch |err| switch (err) {
            error.CompileError => return error.CompileError,
            else => return err,
        };
        const g = try a.create(Global);
        g.* = .{
            .name = d.name,
            .zig_name = try self.globalName(d.name),
            .display = display,
            .node = s,
        };
        try self.globals.put(d.name, g);
    }
}

pub fn emitEntry(self: *Emitter) !void {
    try self.writer.writeAll(
        \\fn lls_finish(err: anyerror) noreturn {
        \\    if (err == error.OutOfMemory) {
        \\        rt.io.failMsg("Out of memory") catch {};
        \\    }
        \\    rt.exitProcess(1);
        \\}
        \\
        \\pub fn main() void {
        \\    var ctx = rt.Context.init(.{}) catch {
        \\        rt.io.writeStderr("Error: out of memory\n");
        \\        rt.exitProcess(1);
        \\    };
        \\    ctx.activate();
        \\    defer ctx.deinit();
        \\    _ = lls_top_level(&ctx) catch |err| lls_finish(err);
        \\
    );
    self.indent = 1;
    try self.writeIndent();
    const main_t = if (self.state.functions.get("main")) |def| try functionReturnType(self, "main", def) else null;
    if (main_t) |t| {
        if (t.may_error) {
            try self.writer.print("const lls_main_result = {s}(&ctx) catch |err| lls_finish(err);\n", .{try self.fnName("main")});
            try self.writeIndent();
            if (t.kind == .error_value) {
                try self.writer.writeAll("rt.io.failMsg(lls_main_result.code) catch {};\n");
                try self.writeIndent();
                try self.writer.writeAll("rt.exitProcess(1);\n");
            } else {
                try self.writer.writeAll("switch (lls_main_result) {\n");
                self.indent += 1;
                try self.writeIndent();
                try self.writer.writeAll(".ok => {},\n");
                try self.writeIndent();
                try self.writer.writeAll(".err => |e| {\n");
                self.indent += 1;
                try self.writeIndent();
                try self.writer.writeAll("rt.io.failMsg(e.code) catch {};\n");
                try self.writeIndent();
                try self.writer.writeAll("rt.exitProcess(1);\n");
                self.indent -= 1;
                try self.writeIndent();
                try self.writer.writeAll("},\n");
                self.indent -= 1;
                try self.writeIndent();
                try self.writer.writeAll("}\n");
            }
        } else {
            try self.writer.print("_ = {s}(&ctx) catch |err| lls_finish(err);\n", .{try self.fnName("main")});
        }
    } else {
        try self.writer.print("_ = {s}(&ctx) catch |err| lls_finish(err);\n", .{try self.fnName("main")});
    }
    try self.writer.writeAll("}\n");
}

pub fn emitFunction(self: *Emitter, name: []const u8, def: state_mod.FunctionDef) !void {
    if (def.node.* != .function_decl) {
        return self.failAt(def.node, "native backend cannot emit non-function '{s}'", .{name});
    }
    const f = &def.node.function_decl;
    const params = switch (f.params.*) {
        .params => |p| p.params,
        else => return self.failAt(f.params, "native backend cannot emit this parameter list", .{}),
    };
    if (f.params.params.is_variadic) {
        return self.failAt(f.params, "native backend does not support variadic functions yet", .{});
    }

    try prepareFunction(self, f, params);
    const ret = try functionReturnType(self, name, def);
    self.cur_ret = ret;

    const zig_fn = try self.fnName(name);
    try self.writer.print("fn {s}(ctx: *rt.Context", .{zig_fn});
    for (self.params.items) |p| {
        try self.writer.print(", {s}: {s}", .{ p.arg_name, p.zig });
    }
    try self.writer.print(") anyerror!{s} {{\n", .{ret.zig});
    self.indent = 1;

    const file = if (f.loc.path.len > 0) f.loc.path else self.doc.path;
    try self.writeIndent();
    try self.writer.print("const _mark = try ctx.enterFunction({s}, {s});\n", .{
        try self.zigString(name),
        try self.zigString(file),
    });
    try self.writeIndent();
    try self.writer.writeAll("defer ctx.leaveFunction(_mark);\n");

    // Parameters: copy mutable ones into locals; silence unread ones.
    for (self.params.items) |p| {
        const b = self.scopes.items[0].get(p.name).?;
        const needs_var = b.reassigned or (b.assigned and p.kind != .pointer and p.kind != .slice);
        if (needs_var) {
            b.zig_name = try self.localName(p.name);
            try self.writeIndent();
            try self.writer.print("var {s}: {s} = {s};\n", .{ b.zig_name, p.zig, p.arg_name });
            if (!b.read) {
                try self.writeIndent();
                try self.writer.print("_ = &{s};\n", .{b.zig_name});
            }
        } else if (!b.read) {
            try self.writeIndent();
            try self.writer.print("_ = {s};\n", .{p.arg_name});
        }
    }

    const block = switch (f.body.*) {
        .block => |b| b,
        else => return self.failAt(f.body, "native backend expects a block body", .{}),
    };
    self.pushScope();
    try stmt_mod.emitStatements(self, block.statements);
    try self.emitDeferredAtScopeEnd(block.statements);
    const terminates = block.statements.len > 0 and prescan_mod.stmtTerminates(self, block.statements[block.statements.len - 1]);
    if (!terminates and ret.may_error) {
        if (ret.kind == .error_value) {
            self.popScope();
            return self.failAt(f.body, "function returning '{s}' must return an error value", .{ret.display});
        }
        const success = ret.success orelse {
            self.popScope();
            return self.failAt(f.body, "native backend cannot determine the success type of '{s}'", .{ret.display});
        };
        try self.writeIndent();
        if (success.kind == .void) {
            try self.writer.writeAll("return .{ .ok = {} };\n");
        } else {
            try self.writer.print("return .{{ .ok = {s} }};\n", .{try zeroValue(self, success.*)});
        }
    }
    self.popScope();

    try self.writer.writeAll("}\n\n");
}

pub fn emitFunctions(self: *Emitter) !void {
    const a = self.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    if (self.reach) |*r| {
        var it = r.functions.keyIterator();
        while (it.next()) |name| try names.append(a, name.*);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names.items) |name| {
        const def = self.state.functions.get(name) orelse continue;
        try emitFunction(self, name, def);
    }
}

pub fn emitGlobalDecls(self: *Emitter) !void {
    const a = self.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = self.globals.keyIterator();
    while (it.next()) |name| try names.append(a, name.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (names.items) |name| {
        const g = self.globals.get(name).?;
        const vt = try self.classify(g.node, g.display);
        try self.requireValueType(g.node, vt);
        try self.writer.print("var {s}: {s} = {s};\n", .{ g.zig_name, vt.zig, try zeroValue(self, vt) });
    }
    if (self.globals.count() > 0) try self.writer.writeAll("\n");
}

pub fn emitTopLevel(self: *Emitter) !void {
    self.cur_ret = .{ .display = "void", .clean = "void", .kind = .void, .zig = "void" };
    try self.writer.writeAll("fn lls_top_level(ctx: *rt.Context) anyerror!void {\n");
    self.indent = 1;
    try self.writeIndent();
    try self.writer.writeAll("ctx.setLine(0, 0);\n");
    self.pushScope();
    for (self.doc.statements) |s| {
        if (s.* == .function_decl or s.* == .struct_decl or s.* == .enum_decl or
            s.* == .error_decl or s.* == .type_decl or s.* == .extern_decl) continue;
        if (self.reach) |*r| {
            if (!r.shouldEmitTopLevel(self.doc, s)) continue;
        }
        if (s.* == .declaration) {
            const d = &s.declaration;
            if (root_mod.isImportDecl(d)) continue;
            const g = self.globals.get(d.name) orelse {
                return self.failAt(s, "native backend (Phase 2) does not support this top-level declaration", .{});
            };
            try stmt_mod.emitLineMarker(self, s);
            const vt = try self.classify(s, g.display);
            const code = try expr_mod.emitValueCoerced(self, d.value, vt);
            try self.writeIndent();
            try self.writer.print("{s} = {s};\n", .{ g.zig_name, code });
            continue;
        }
        try stmt_mod.emitStmt(self, s);
    }
    self.popScope();
    try self.writer.writeAll("}\n\n");
}

pub fn functionReturnType(self: *Emitter, name: []const u8, def: state_mod.FunctionDef) !ValType {
    var display = def.return_type orelse blk: {
        if (def.node.* == .function_decl) {
            if (def.node.function_decl.return_type) |rt| {
                if (try from_ast.typeAstToDisplay(rt, self.state)) |disp| break :blk disp;
            }
        }
        break :blk "void";
    };
    if (def.node.* == .function_decl) {
        const f = def.node.function_decl;
        const raw = if (f.return_type) |rt| try from_ast.typeAstToDisplay(rt, self.state) else null;
        if (raw) |r| {
            if (std.mem.eql(u8, r, "error")) display = "error";
        } else if (std.mem.eql(u8, display, "unknown | error")) {
            if (!bodyHasValuedReturn(f.body)) {
                display = "void | error";
            } else if (bodyReturnsOnlyErrors(self.state, f.body)) {
                display = "error";
            }
        }
    }
    const t = try self.classify(def.node, display);
    if (t.clean.len == 0) {
        return self.failAt(def.node, "native backend does not support the return type of '{s}'", .{name});
    }
    if (t.kind == .other) {
        return self.failAt(def.node, "native backend (Phase 2) does not support return type '{s}'", .{display});
    }
    return t;
}

pub fn prepareFunction(self: *Emitter, f: *const ast_mod.FunctionDecl, params: []const ast_mod.Param) !void {
    const a = self.arena.allocator();
    self.infos.clearRetainingCapacity();
    self.scopes.clearRetainingCapacity();
    self.params.clearRetainingCapacity();
    self.break_targets.clearRetainingCapacity();
    self.defer_scopes.clearRetainingCapacity();

    var base = std.StringHashMap(*Binding).init(a);
    for (params) |p| {
        if (p.is_rest) return self.failAt(f.params, "native backend does not support rest parameters yet", .{});
        const display = if (p.type_annotation) |ann|
            (try from_ast.typeAstToDisplay(ann, self.state)) orelse "unknown"
        else
            "unknown";
        const vt = try self.classify(f.params, display);
        try self.requireValueType(f.params, vt);
        const b = try a.create(Binding);
        b.* = .{
            .name = p.name,
            .zig_name = try self.paramArgName(p.name),
            .display = display,
            .is_param = true,
        };
        try base.put(p.name, b);
        try self.params.append(a, .{
            .name = p.name,
            .arg_name = b.zig_name,
            .display = display,
            .zig = vt.zig,
            .kind = vt.kind,
        });
    }
    try self.scopes.append(a, base);
    try self.defer_scopes.append(a, .empty);

    try prescan_mod.preScanStmt(self, f.body);
}

pub fn zeroValue(self: *Emitter, t: ValType) ![]const u8 {
    return switch (t.kind) {
        .int => "0",
        .float => "0.0",
        .bool => "false",
        .string => "\"\"",
        .optional, .null_value => "null",
        .struct_, .array, .slice, .pointer => "undefined",
        .error_value, .error_payload => "undefined",
        else => if (t.may_error)
            "undefined"
        else
            self.failNoLoc("native backend cannot zero-initialize type '{s}'", .{t.display}),
    };
}

fn bodyHasValuedReturn(node: *ast_mod.Node) bool {
    return switch (node.*) {
        .return_expr => |r| r.return_value != null,
        .block => |b| blk: {
            for (b.statements) |s| if (bodyHasValuedReturn(s)) break :blk true;
            break :blk false;
        },
        .if_expr => |i| bodyHasValuedReturn(i.body) or (i.else_body != null and bodyHasValuedReturn(i.else_body.?)),
        .switch_expr => |sw| blk: {
            for (sw.prongs) |p| if (bodyHasValuedReturn(p.body)) break :blk true;
            break :blk false;
        },
        .for_expr => |f| bodyHasValuedReturn(f.body),
        .defer_stmt => |d| bodyHasValuedReturn(d.body),
        else => false,
    };
}

fn bodyReturnsOnlyErrors(state: *state_mod.CompilerState, node: *ast_mod.Node) bool {
    return switch (node.*) {
        .return_expr => |r| blk: {
            const v = r.return_value orelse break :blk true;
            if (v.* == .error_expr) break :blk true;
            const disp = state.type_of_results.get(v) orelse break :blk false;
            break :blk isPureErrorDisplay(state, disp);
        },
        .block => |b| blk: {
            for (b.statements) |s| if (!bodyReturnsOnlyErrors(state, s)) break :blk false;
            break :blk true;
        },
        .if_expr => |i| bodyReturnsOnlyErrors(state, i.body) and (i.else_body == null or bodyReturnsOnlyErrors(state, i.else_body.?)),
        .switch_expr => |sw| blk: {
            for (sw.prongs) |p| if (!bodyReturnsOnlyErrors(state, p.body)) break :blk false;
            break :blk true;
        },
        .for_expr => |f| bodyReturnsOnlyErrors(state, f.body),
        .defer_stmt => |d| bodyReturnsOnlyErrors(state, d.body),
        else => true,
    };
}

fn isPureErrorDisplay(state: *state_mod.CompilerState, display: []const u8) bool {
    if (std.mem.eql(u8, display, "error")) return true;
    if (state.error_sets.contains(display)) return true;
    if (std.mem.lastIndexOfScalar(u8, display, '.')) |dot| {
        return state.error_sets.contains(display[0..dot]);
    }
    return false;
}
