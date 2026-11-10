const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const state_mod = @import("../../state.zig");
const from_ast = @import("../../typecheck/from_ast.zig");
const ir = @import("../../typecheck/ir.zig");
const root_mod = @import("root.zig");
const stmt_mod = @import("stmt.zig");
const expr_mod = @import("expr.zig");
const range_mod = @import("range.zig");
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
        const fn_key: ?[]const u8 = blk: {
            if (d.value.* == .primary and (d.value.primary.kind == .identifier or d.value.primary.kind == .register)) {
                if (self.state.functions.contains(d.value.primary.name)) break :blk d.value.primary.name;
            }
            if (self.state.type_ir_of_results.get(d.value)) |t| {
                if (ir.peelDefined(t) == .func) break :blk d.name;
            }
            break :blk null;
        };
        const module_path = if (fn_key == null) self.resolveModuleValue(d.value) else null;
        const display = if (fn_key != null)
            "func"
        else if (module_path != null)
            "module"
        else
            self.displayForDeclValue(d) catch |err| switch (err) {
                error.CompileError => return error.CompileError,
                else => return err,
            };
        const g = try a.create(Global);
        g.* = .{
            .name = d.name,
            .zig_name = try self.globalName(d.name),
            .display = display,
            .ir_type = if (fn_key != null or module_path != null) null else self.declaredIRType(d),
            .node = s,
            .fn_key = fn_key,
            .module_path = module_path,
        };
        try self.globals.put(d.name, g);
        if (d.is_const) {
            if (range_mod.ofExpr(self, d.value)) |int_range| {
                try self.int_ranges.put(@intFromPtr(g), int_range);
            }
        }
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
        \\    ctx.setTraceSites(lls_trace_sites[0..]);
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
                try self.writer.writeAll("rt.io.failMsg(lls_main_result.message) catch {};\n");
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
                try self.writer.writeAll("rt.io.failMsg(e.message) catch {};\n");
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

    try prepareFunction(self, f, params, self.methodStructFor(name));
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
    self.current_trace_func = name;
    self.current_trace_file = file;
    const entry_site = try self.addTraceSite(name, file, 0, 0);
    try self.writeIndent();
    try self.writer.print("const _mark = try ctx.enterFunction({d});\n", .{entry_site});
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
    const terminates = block.statements.len > 0 and (self.state.terminates.get(block.statements[block.statements.len - 1]) orelse false);
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
        if (g.fn_key != null or g.module_path != null) continue;
        const vt = try self.valTypeFor(g.node, g.ir_type, g.display);
        try self.requireValueType(g.node, vt);
        try self.writer.print("var {s}: {s} = {s};\n", .{ g.zig_name, vt.zig, try zeroValue(self, vt) });
    }
    if (self.globals.count() > 0) try self.writer.writeAll("\n");
}

pub fn emitTopLevel(self: *Emitter) !void {
    self.cur_ret = .{ .display = "void", .clean = "void", .kind = .void, .zig = "void" };
    self.current_trace_func = null;
    self.current_trace_file = "";
    try self.writer.writeAll("fn lls_top_level(ctx: *rt.Context) anyerror!void {\n");
    self.indent = 1;
    try self.writeIndent();
    try self.writer.writeAll("ctx.setSite(0);\n");
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
            if (g.fn_key != null or g.module_path != null) continue;
            try stmt_mod.emitLineMarker(self, s);
            const vt = try self.valTypeFor(s, g.ir_type, g.display);
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
    const display = def.return_type orelse blk: {
        if (def.node.* == .function_decl) {
            if (def.node.function_decl.return_type) |rt| {
                if (try from_ast.typeAstToDisplay(rt, self.state)) |disp| break :blk disp;
            }
        }
        break :blk "void";
    };
    const t = try self.valTypeFor(def.node, def.return_ir, display);
    if (t.clean.len == 0) {
        return self.failAt(def.node, "native backend does not support the return type of '{s}'", .{name});
    }
    if (t.kind == .other) {
        return self.failAt(def.node, "native backend (Phase 2) does not support return type '{s}'", .{display});
    }
    return t;
}

pub fn prepareFunction(
    self: *Emitter,
    f: *const ast_mod.FunctionDecl,
    params: []const ast_mod.Param,
    method_struct: ?[]const u8,
) !void {
    const a = self.arena.allocator();
    self.infos.clearRetainingCapacity();
    self.scopes.clearRetainingCapacity();
    self.params.clearRetainingCapacity();
    self.break_targets.clearRetainingCapacity();
    self.defer_scopes.clearRetainingCapacity();

    var base = std.StringHashMap(*Binding).init(a);
    for (params, 0..) |p, i| {
        if (p.is_rest) return self.failAt(f.params, "native backend does not support rest parameters yet", .{});
        var display = if (p.type_annotation) |ann|
            (try from_ast.typeAstToDisplay(ann, self.state)) orelse "unknown"
        else
            "unknown";
        // Unannotated method `self` is pointer-like (`*T`): mutations through it
        // are visible to the caller, matching the VM's shared-handle receiver.
        if (i == 0 and method_struct != null and p.type_annotation == null and
            std.mem.eql(u8, p.name, "self"))
        {
            display = try std.fmt.allocPrint(a, "*{s}", .{method_struct.?});
        }
        var ir_type: ?ir.Type = null;
        if (p.type_annotation) |ann| {
            ir_type = from_ast.typeFromAst(ann, self.state, self.state.typeAlloc()) catch null;
        } else if (i == 0 and method_struct != null and std.mem.eql(u8, p.name, "self")) {
            const struct_ty: ir.Type = .{ .struct_ = method_struct.? };
            ir_type = try self.state.typeAlloc().ptrType(struct_ty);
        }
        const vt = try self.valTypeFor(f.params, ir_type, display);
        try self.requireValueType(f.params, vt);
        const b = try a.create(Binding);
        b.* = .{
            .name = p.name,
            .zig_name = try self.paramArgName(p.name),
            .display = display,
            .ir_type = ir_type,
            .is_param = true,
        };
        // Initialize mutation/read flags from the compiler-recorded facts.
        if (self.state.param_facts.get(&p)) |facts| {
            b.read = facts.read;
            b.assigned = facts.assigned;
            b.reassigned = facts.reassigned;
        }
        try base.put(p.name, b);
        try self.params.append(a, .{
            .name = p.name,
            .arg_name = b.zig_name,
            .display = display,
            .ir_type = ir_type,
            .zig = vt.zig,
            .kind = vt.kind,
        });
    }
    try self.scopes.append(a, base);
    try self.defer_scopes.append(a, .empty);
}

pub fn zeroValue(self: *Emitter, t: ValType) ![]const u8 {
    return switch (t.kind) {
        .int => "0",
        .float => "0.0",
        .bool => "false",
        .string => "\"\"",
        .optional, .null_value => "null",
        .struct_, .array, .slice, .pointer => "undefined",
        .error_value => "undefined",
        else => if (t.may_error)
            "undefined"
        else
            self.failNoLoc("native backend cannot zero-initialize type '{s}'", .{t.display}),
    };
}

