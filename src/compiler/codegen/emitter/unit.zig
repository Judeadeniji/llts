const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const state_mod = @import("../../state.zig");
const from_ast = @import("../../typecheck/from_ast.zig");
const root_mod = @import("root.zig");
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
    try self.writer.print("_ = {s}(&ctx) catch |err| lls_finish(err);\n", .{try self.fnName("main")});
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

    try self.prepareFunction(f, params);
    const ret = try self.functionReturnType(name, def);
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
        if (b.assigned) {
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
    try self.emitStatements(block.statements);
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
        try self.emitFunction(name, def);
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
        try self.writer.print("var {s}: {s} = {s};\n", .{ g.zig_name, vt.zig, try self.zeroValue(vt) });
    }
    if (self.globals.count() > 0) try self.writer.writeAll("\n");
}

pub fn emitTopLevel(self: *Emitter) !void {
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
            try self.emitLineMarker(s);
            const vt = try self.classify(s, g.display);
            const code = try self.emitValueCoerced(d.value, vt);
            try self.writeIndent();
            try self.writer.print("{s} = {s};\n", .{ g.zig_name, code });
            continue;
        }
        try self.emitStmt(s);
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
        });
    }
    try self.scopes.append(a, base);

    try self.preScanStmt(f.body);
}

pub fn zeroValue(self: *Emitter, t: ValType) ![]const u8 {
    return switch (t.kind) {
        .int => "0",
        .float => "0.0",
        .bool => "false",
        .string => "\"\"",
        else => self.failNoLoc("native backend cannot zero-initialize type '{s}'", .{t.display}),
    };
}
