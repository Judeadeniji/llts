const std = @import("std");
const state_mod = @import("state.zig");
const ast = @import("../ast/root.zig");
const scanner = @import("../scanner/root.zig");
const parser = @import("../parser/root.zig");

const CompilerState = state_mod.CompilerState;
const ModuleError = error{ OutOfMemory, CompileError };
const report = @import("../errors/report.zig");

fn reportImportStack(state: *CompilerState) void {
    // Print outermost → innermost so the `@import` chain reads like a call stack
    // after the faulting scan/parse frame (already printed).
    var i: isize = @intCast(state.import_stack.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const f = state.import_stack.items[@intCast(i)];
        var name_buf: [256]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "@import(\"{s}\")", .{f.import_path}) catch "@import";
        report.reportLocationFrameCol(f.path, f.line, f.column, name);
    }
}

/// Resolve `@import` nodes: load, parse, and qualify public decls into `doc`.
pub fn resolveImports(state: *CompilerState, doc: *ast.Document) ModuleError!void {
    var visited = std.StringHashMap(void).init(state.allocator);
    defer visited.deinit();
    try resolveImportsInner(state, doc, null, &visited);
}

pub const ImportSite = struct {
    path: []const u8,
    loc: ast.Location,
};

pub fn getImportSite(node: *ast.Node) ?ImportSite {
    if (node.* == .call) {
        const callee = node.call.callee;
        if (callee.* == .primary and std.mem.eql(u8, callee.primary.name, "@import")) {
            if (node.call.args.len == 1 and node.call.args[0].* == .literal and node.call.args[0].literal.literal_type == .string) {
                return .{
                    .path = node.call.args[0].literal.value,
                    .loc = callee.loc(),
                };
            }
        }
    }
    return null;
}

/// Resolve an `@import("path")` string to the module key used in qualified names.
pub fn resolveImportKey(state: *CompilerState, from_path: []const u8, import_path: []const u8) ModuleError![]const u8 {
    const resolved = try resolvePath(state, from_path, import_path);
    try state.owned.append(state.allocator, resolved);
    return moduleKey(resolved);
}

fn treeContainsImport(node: *ast.Node) bool {
    if (getImportSite(node) != null) return true;
    switch (node.*) {
        .function_decl => |f| {
            if (f.return_type) |rt| if (treeContainsImport(rt)) return true;
            return treeContainsImport(f.body);
        },
        .struct_decl => |st| {
            for (st.fields) |field| {
                if (field.type_annotation) |ta| if (treeContainsImport(ta)) return true;
            }
            for (st.methods) |m| if (treeContainsImport(m)) return true;
            return false;
        },
        .enum_decl => {},
        .block => |b| {
            for (b.statements) |s| if (treeContainsImport(s)) return true;
            return false;
        },
        .declaration => |d| {
            if (d.type_annotation) |ta| if (treeContainsImport(ta)) return true;
            return treeContainsImport(d.value);
        },
        .struct_init => |init| {
            if (treeContainsImport(init.type_expr)) return true;
            for (init.fields) |f| if (treeContainsImport(f.value)) return true;
            return false;
        },
        .for_expr => |f| {
            if (treeContainsImport(f.expr)) return true;
            return treeContainsImport(f.body);
        },
        .if_expr => |i| {
            if (treeContainsImport(i.condition)) return true;
            if (i.pipe_value) |pv| if (treeContainsImport(pv)) return true;
            if (treeContainsImport(i.body)) return true;
            if (i.else_body) |e| if (treeContainsImport(e)) return true;
            return false;
        },
        .switch_expr => |sw| {
            if (treeContainsImport(sw.condition)) return true;
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| if (treeContainsImport(pat)) return true;
                if (treeContainsImport(prong.body)) return true;
            }
            return false;
        },
        .break_expr => |br| {
            if (br.value) |v| return treeContainsImport(v);
            return false;
        },
        .binary => |b| return treeContainsImport(b.left) or treeContainsImport(b.right),
        .unary => |u| return treeContainsImport(u.arg),
        .assignment => |a| return treeContainsImport(a.left) or treeContainsImport(a.right),
        .call => |c| {
            if (treeContainsImport(c.callee)) return true;
            for (c.args) |a| if (treeContainsImport(a)) return true;
            return false;
        },
        .member => |m| return treeContainsImport(m.object),
        .index => |ix| {
            if (treeContainsImport(ix.object)) return true;
            if (ix.index) |start| if (treeContainsImport(start)) return true;
            if (ix.end) |end| if (treeContainsImport(end)) return true;
            if (ix.type_annotation) |ta| if (treeContainsImport(ta)) return true;
            return false;
        },
        .array_literal => |a| {
            for (a.elements) |e| if (treeContainsImport(e)) return true;
            return false;
        },
        .return_expr => |r| {
            if (r.return_value) |v| return treeContainsImport(v);
            return false;
        },
        .defer_stmt => |d| return treeContainsImport(d.body),
        .try_expr => |t| return treeContainsImport(t.expression),
        .error_expr => |e| return treeContainsImport(e.args[0]),
        .params => |p| {
            for (p.params) |param| {
                if (param.type_annotation) |ta| if (treeContainsImport(ta)) return true;
            }
            return false;
        },
        .array_type => |a| return treeContainsImport(a.elem),
        .pointer_type => |p| return treeContainsImport(p.elem),
        .union_type => |u| return treeContainsImport(u.left) or treeContainsImport(u.right),
        else => {},
    }
    return false;
}

fn loadImportsInTree(
    state: *CompilerState,
    doc: *ast.Document,
    node: *ast.Node,
    current_module: ?[]const u8,
    out: *std.ArrayList(*ast.Node),
    visited: *std.StringHashMap(void),
) ModuleError!void {
    switch (node.*) {
        .function_decl => |f| {
            if (f.return_type) |rt| try loadImportsInTree(state, doc, rt, current_module, out, visited);
            try loadImportsInTree(state, doc, f.body, current_module, out, visited);
        },
        .struct_decl => |st| {
            for (st.fields) |field| {
                if (field.type_annotation) |ta| try loadImportsInTree(state, doc, ta, current_module, out, visited);
            }
            for (st.methods) |m| try loadImportsInTree(state, doc, m, current_module, out, visited);
        },
        .enum_decl => {},
        .block => |b| {
            for (b.statements) |s| try loadImportsInTree(state, doc, s, current_module, out, visited);
        },
        .declaration => |d| {
            if (getImportSite(d.value)) |imp| {
                try loadModule(state, doc, imp.path, d.name, current_module, out, visited, imp.loc);
            } else {
                if (d.type_annotation) |ta| try loadImportsInTree(state, doc, ta, current_module, out, visited);
                try loadImportsInTree(state, doc, d.value, current_module, out, visited);
            }
        },
        .struct_init => |init| {
            try loadImportsInTree(state, doc, init.type_expr, current_module, out, visited);
            for (init.fields) |f| try loadImportsInTree(state, doc, f.value, current_module, out, visited);
        },
        .for_expr => |f| {
            try loadImportsInTree(state, doc, f.expr, current_module, out, visited);
            try loadImportsInTree(state, doc, f.body, current_module, out, visited);
        },
        .if_expr => |i| {
            try loadImportsInTree(state, doc, i.condition, current_module, out, visited);
            if (i.pipe_value) |pv| try loadImportsInTree(state, doc, pv, current_module, out, visited);
            try loadImportsInTree(state, doc, i.body, current_module, out, visited);
            if (i.else_body) |e| try loadImportsInTree(state, doc, e, current_module, out, visited);
        },
        .switch_expr => |sw| {
            try loadImportsInTree(state, doc, sw.condition, current_module, out, visited);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| try loadImportsInTree(state, doc, pat, current_module, out, visited);
                try loadImportsInTree(state, doc, prong.body, current_module, out, visited);
            }
        },
        .break_expr => |br| {
            if (br.value) |v| try loadImportsInTree(state, doc, v, current_module, out, visited);
        },
        .binary => |b| {
            try loadImportsInTree(state, doc, b.left, current_module, out, visited);
            try loadImportsInTree(state, doc, b.right, current_module, out, visited);
        },
        .unary => |u| try loadImportsInTree(state, doc, u.arg, current_module, out, visited),
        .assignment => |a| {
            try loadImportsInTree(state, doc, a.left, current_module, out, visited);
            try loadImportsInTree(state, doc, a.right, current_module, out, visited);
        },
        .call => |c| {
            if (getImportSite(node)) |imp| {
                try loadModule(state, doc, imp.path, null, current_module, out, visited, imp.loc);
            } else {
                try loadImportsInTree(state, doc, c.callee, current_module, out, visited);
                for (c.args) |a| try loadImportsInTree(state, doc, a, current_module, out, visited);
            }
        },
        .member => |m| try loadImportsInTree(state, doc, m.object, current_module, out, visited),
        .index => |ix| {
            try loadImportsInTree(state, doc, ix.object, current_module, out, visited);
            if (ix.index) |start| try loadImportsInTree(state, doc, start, current_module, out, visited);
            if (ix.end) |end| try loadImportsInTree(state, doc, end, current_module, out, visited);
            if (ix.type_annotation) |ta| try loadImportsInTree(state, doc, ta, current_module, out, visited);
        },
        .array_literal => |a| {
            for (a.elements) |e| try loadImportsInTree(state, doc, e, current_module, out, visited);
        },
        .return_expr => |r| {
            if (r.return_value) |v| try loadImportsInTree(state, doc, v, current_module, out, visited);
        },
        .defer_stmt => |d| try loadImportsInTree(state, doc, d.body, current_module, out, visited),
        .try_expr => |t| try loadImportsInTree(state, doc, t.expression, current_module, out, visited),
        .error_expr => |e| try loadImportsInTree(state, doc, e.args[0], current_module, out, visited),
        .params => |p| {
            for (p.params) |param| {
                if (param.type_annotation) |ta| try loadImportsInTree(state, doc, ta, current_module, out, visited);
            }
        },
        .array_type => |a| {
            try loadImportsInTree(state, doc, a.elem, current_module, out, visited);
        },
        .pointer_type => |p| {
            try loadImportsInTree(state, doc, p.elem, current_module, out, visited);
        },
        .union_type => |u| {
            try loadImportsInTree(state, doc, u.left, current_module, out, visited);
            try loadImportsInTree(state, doc, u.right, current_module, out, visited);
        },
        else => {},
    }
}

fn resolveImportsInner(
    state: *CompilerState,
    doc: *ast.Document,
    current_module: ?[]const u8,
    visited: *std.StringHashMap(void),
) ModuleError!void {
    var has_import = false;
    for (doc.statements) |s| {
        if (treeContainsImport(s)) {
            has_import = true;
            break;
        }
    }
    if (!has_import) return;

    var out: std.ArrayList(*ast.Node) = .empty;
    defer out.deinit(state.allocator);

    for (doc.statements) |s| {
        const is_bound_import = s.* == .declaration and getImportSite(s.declaration.value) != null;
        const is_side_effect_import = getImportSite(s) != null;
        if (!is_bound_import and !is_side_effect_import) {
            try out.append(state.allocator, s);
        }
        try loadImportsInTree(state, doc, s, current_module, &out, visited);
    }

    doc.statements = try doc.arena.allocator().dupe(*ast.Node, out.items);
}

fn loadModule(
    state: *CompilerState,
    doc: *ast.Document,
    import_path: []const u8,
    bind_name: ?[]const u8,
    current_module: ?[]const u8,
    out: *std.ArrayList(*ast.Node),
    visited: *std.StringHashMap(void),
    import_loc: ast.Location,
) ModuleError!void {
    const resolved = try resolvePath(state, doc.path, import_path);
    try state.owned.append(state.allocator, resolved);

    const key = moduleKey(resolved);
    if (bind_name) |name| {
        const mod_val = try std.fmt.allocPrint(state.allocator, "module:{s}", .{key});
        try state.owned.append(state.allocator, mod_val);
        const owned_key = try std.fmt.allocPrint(state.allocator, "${s}", .{name});
        try state.owned.append(state.allocator, owned_key);
        try state.global_types.put(owned_key, mod_val);

        if (current_module) |parent| {
            const owned_pkey = try std.fmt.allocPrint(state.allocator, "${s}::{s}", .{ parent, name });
            try state.owned.append(state.allocator, owned_pkey);
            try state.global_types.put(owned_pkey, mod_val);
        }
    }

    if (visited.contains(resolved)) return;
    try visited.put(resolved, {});

    try state.import_stack.append(state.allocator, .{
        .path = doc.path,
        .line = if (import_loc.line > 0) import_loc.line else 1,
        .column = if (import_loc.column > 0) import_loc.column else 1,
        .import_path = import_path,
    });
    defer _ = state.import_stack.pop();

    // Persist edge so later compile failures in this file can still print the import chain.
    try state.import_from.put(resolved, state.import_stack.items[state.import_stack.items.len - 1]);

    const source = std.fs.cwd().readFileAlloc(state.allocator, resolved, 16 * 1024 * 1024) catch {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "cannot read import '{s}'", .{resolved}) catch "cannot read import";
        const line = if (import_loc.line > 0) import_loc.line else 1;
        const col = if (import_loc.column > 0) import_loc.column else 1;
        report.reportSourceErrorWithFrame(doc.path, doc.source, line, col, msg, "<compile>");
        reportImportStack(state);
        return error.CompileError;
    };
    try state.owned.append(state.allocator, source);

    _ = state.chunk.addSource(resolved, source) catch {};

    var scan_result = scanner.scan(state.allocator, source, resolved) catch {
        reportImportStack(state);
        return error.CompileError;
    };
    defer scanner.deinitScanResult(&scan_result);

    const mod_doc = parser.parse(state.allocator, scan_result.tokens.items, resolved, source) catch {
        reportImportStack(state);
        return error.CompileError;
    };
    const owned_doc = try state.allocator.create(ast.Document);
    owned_doc.* = mod_doc;
    // Keep module arenas alive until compile finishes (nodes are referenced from `doc`).
    try state.module_docs.append(state.allocator, owned_doc);

    try resolveImportsInner(state, owned_doc, key, visited);

    var local_map = try collectLocalBindings(state, owned_doc.statements, key);
    defer local_map.deinit();

    for (owned_doc.statements) |ms| {
        try qualifyNode(state, ms, key, &local_map);
    }
    for (owned_doc.statements) |ms| {
        if (isOwnDecl(ms, key)) {
            var bound: std.ArrayList([]const u8) = .empty;
            defer bound.deinit(state.allocator);
            try rewriteModuleRefs(state, ms, &local_map, &bound);
        }
        try out.append(state.allocator, ms);
    }
}

fn resolvePath(state: *CompilerState, from: []const u8, import_path: []const u8) ModuleError![]const u8 {
    const with_ext = if (std.mem.endsWith(u8, import_path, ".lls"))
        try state.allocator.dupe(u8, import_path)
    else
        try std.fmt.allocPrint(state.allocator, "{s}.lls", .{import_path});

    // 1. relative to cwd
    if (std.fs.cwd().access(with_ext, .{})) |_| {
        return try normalizePath(state, with_ext);
    } else |_| {}

    // 2. parent of cwd (zig/ → repo root)
    const up = try std.fmt.allocPrint(state.allocator, "../{s}", .{with_ext});
    if (std.fs.cwd().access(up, .{})) |_| {
        state.allocator.free(with_ext);
        return try normalizePath(state, up);
    } else |_| {
        state.allocator.free(up);
    }

    // 3. relative to importer
    const dir = std.fs.path.dirname(from) orelse ".";
    const joined = try std.fs.path.join(state.allocator, &.{ dir, with_ext });
    state.allocator.free(with_ext);
    if (std.fs.cwd().access(joined, .{})) |_| {
        return try normalizePath(state, joined);
    } else |_| {}

    state.allocator.free(joined);
    return @import("../errors/compile.zig").compileFailFmt(state, "Unknown module '{s}'", .{import_path});
}

/// Collapse `.` / `..` so diagnostics show `dir/leaf.lls` instead of `dir/././leaf.lls`.
fn normalizePath(state: *CompilerState, path: []const u8) ModuleError![]const u8 {
    const cleaned = try std.fs.path.resolve(state.allocator, &.{path});
    state.allocator.free(path);
    return cleaned;
}

fn collectLocalBindings(
    state: *CompilerState,
    statements: []*ast.Node,
    module_path: []const u8,
) ModuleError!std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(state.allocator);
    errdefer map.deinit();
    for (statements) |s| {
        const name: ?[]const u8 = switch (s.*) {
            .struct_decl => |st| st.name,
            .enum_decl => |e| e.name,
            .function_decl => |f| f.name,
            .declaration => |d| d.name,
            .extern_decl => |e| e.name,
            else => null,
        };
        if (name) |n| {
            if (std.mem.indexOf(u8, n, "::") != null) continue;
            const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ module_path, n });
            try state.owned.append(state.allocator, q);
            try map.put(n, q);
        }
    }
    return map;
}

fn isOwnDecl(node: *ast.Node, mod_key: []const u8) bool {
    const name: ?[]const u8 = switch (node.*) {
        .struct_decl => |st| st.name,
        .enum_decl => |e| e.name,
        .function_decl => |f| f.name,
        .declaration => |d| d.name,
        .extern_decl => |e| e.name,
        else => null,
    };
    if (name) |n| {
        if (!std.mem.startsWith(u8, n, mod_key)) return false;
        if (n.len <= mod_key.len) return false;
        return n[mod_key.len] == ':' and n[mod_key.len + 1] == ':';
    }
    return false;
}

fn qualifyNode(
    state: *CompilerState,
    node: *ast.Node,
    mod_key: []const u8,
    local_map: *std.StringHashMap([]const u8),
) ModuleError!void {
    switch (node.*) {
        .function_decl => |*f| {
            if (std.mem.indexOf(u8, f.name, "::") != null) return;
            f.name = local_map.get(f.name) orelse blk: {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, f.name });
                try state.owned.append(state.allocator, q);
                break :blk q;
            };
            if (f.is_public) try state.chunk.exports.put(f.name, {});
        },
        .declaration => |*d| {
            if (std.mem.indexOf(u8, d.name, "::") != null) return;
            d.name = local_map.get(d.name) orelse blk: {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, d.name });
                try state.owned.append(state.allocator, q);
                break :blk q;
            };
            if (d.is_public) try state.chunk.exports.put(d.name, {});
        },
        .extern_decl => |*e| {
            if (std.mem.indexOf(u8, e.name, "::") != null) return;
            e.name = local_map.get(e.name) orelse blk: {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, e.name });
                try state.owned.append(state.allocator, q);
                break :blk q;
            };
            if (e.is_public) try state.chunk.exports.put(e.name, {});
        },
        .struct_decl => |*st| {
            if (std.mem.indexOf(u8, st.name, "::") != null) return;
            const short = st.name;
            st.name = local_map.get(short) orelse blk: {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, short });
                try state.owned.append(state.allocator, q);
                break :blk q;
            };
            if (st.is_public) try state.chunk.exports.put(st.name, {});
            for (st.methods) |m| {
                if (m.* != .function_decl) continue;
                const mn = m.function_decl.name;
                // Parser pre-mangles to `Arena::alloc`; requalify under module key.
                if (std.mem.indexOf(u8, mn, "::")) |idx| {
                    const method_short = mn[idx + 2 ..];
                    const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ st.name, method_short });
                    try state.owned.append(state.allocator, q);
                    m.function_decl.name = q;
                    if (st.is_public) try state.chunk.exports.put(q, {});
                } else {
                    const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ st.name, mn });
                    try state.owned.append(state.allocator, q);
                    m.function_decl.name = q;
                    if (st.is_public) try state.chunk.exports.put(q, {});
                }
            }
        },
        .enum_decl => |*en| {
            if (std.mem.indexOf(u8, en.name, "::") != null) return;
            const short = en.name;
            en.name = local_map.get(short) orelse blk: {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, short });
                try state.owned.append(state.allocator, q);
                break :blk q;
            };
            if (en.is_public) try state.chunk.exports.put(en.name, {});
        },
        else => {},
    }
}

fn boundContains(bound: *std.ArrayList([]const u8), name: []const u8) bool {
    for (bound.items) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

fn rewriteModuleRefs(
    state: *CompilerState,
    node: *ast.Node,
    local_map: *std.StringHashMap([]const u8),
    bound: *std.ArrayList([]const u8),
) ModuleError!void {
    switch (node.*) {
        .function_decl => |*f| {
            const mark = bound.items.len;
            if (f.params.* == .params) {
                for (f.params.params.params) |p| {
                    try bound.append(state.allocator, p.name);
                }
            }
            if (f.return_type) |rt| try rewriteModuleRefs(state, rt, local_map, bound);
            try rewriteModuleRefs(state, f.body, local_map, bound);
            bound.shrinkRetainingCapacity(mark);
        },
        .struct_decl => |*st| {
            for (st.fields) |field| {
                if (field.type_annotation) |ta| try rewriteModuleRefs(state, ta, local_map, bound);
            }
            for (st.methods) |m| try rewriteModuleRefs(state, m, local_map, bound);
        },
        .enum_decl => {},
        .block => |*b| {
            const mark = bound.items.len;
            for (b.statements) |s| try rewriteModuleRefs(state, s, local_map, bound);
            bound.shrinkRetainingCapacity(mark);
        },
        .declaration => |*d| {
            if (d.type_annotation) |ta| try rewriteModuleRefs(state, ta, local_map, bound);
            try rewriteModuleRefs(state, d.value, local_map, bound);
            try bound.append(state.allocator, d.name);
        },
        .primary => |*p| {
            if (p.kind == .identifier) {
                if (local_map.get(p.name)) |q| {
                    if (!boundContains(bound, p.name)) p.name = q;
                }
            }
        },
        .struct_init => |*init| {
            try rewriteModuleRefs(state, init.type_expr, local_map, bound);
            for (init.fields) |*f| {
                try rewriteModuleRefs(state, f.value, local_map, bound);
            }
        },
        .for_expr => |*f| {
            try rewriteModuleRefs(state, f.expr, local_map, bound);
            const mark = bound.items.len;
            for (f.captures) |c| try bound.append(state.allocator, c.name);
            try rewriteModuleRefs(state, f.body, local_map, bound);
            bound.shrinkRetainingCapacity(mark);
        },
        .if_expr => |*i| {
            try rewriteModuleRefs(state, i.condition, local_map, bound);
            if (i.pipe_value) |pv| try rewriteModuleRefs(state, pv, local_map, bound);
            try rewriteModuleRefs(state, i.body, local_map, bound);
            if (i.else_body) |e| try rewriteModuleRefs(state, e, local_map, bound);
        },
        .switch_expr => |*sw| {
            try rewriteModuleRefs(state, sw.condition, local_map, bound);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| try rewriteModuleRefs(state, pat, local_map, bound);
                try rewriteModuleRefs(state, prong.body, local_map, bound);
            }
        },
        .break_expr => |*br| {
            if (br.value) |v| try rewriteModuleRefs(state, v, local_map, bound);
        },
        .binary => |*b| {
            try rewriteModuleRefs(state, b.left, local_map, bound);
            try rewriteModuleRefs(state, b.right, local_map, bound);
        },
        .unary => |*u| try rewriteModuleRefs(state, u.arg, local_map, bound),
        .assignment => |*a| {
            try rewriteModuleRefs(state, a.left, local_map, bound);
            try rewriteModuleRefs(state, a.right, local_map, bound);
        },
        .call => |*c| {
            try rewriteModuleRefs(state, c.callee, local_map, bound);
            for (c.args) |a| try rewriteModuleRefs(state, a, local_map, bound);
        },
        .member => |*m| {
            try rewriteModuleRefs(state, m.object, local_map, bound);
            // Keep property short names (`syscall.mkdir` must not become `syscall.mod::mkdir`).
        },
        .index => |*ix| {
            try rewriteModuleRefs(state, ix.object, local_map, bound);
            if (ix.index) |start| try rewriteModuleRefs(state, start, local_map, bound);
            if (ix.end) |end| try rewriteModuleRefs(state, end, local_map, bound);
            if (ix.type_annotation) |ta| try rewriteModuleRefs(state, ta, local_map, bound);
        },
        .array_literal => |*a| {
            for (a.elements) |e| try rewriteModuleRefs(state, e, local_map, bound);
        },
        .return_expr => |*r| {
            if (r.return_value) |v| try rewriteModuleRefs(state, v, local_map, bound);
        },
        .defer_stmt => |*d| try rewriteModuleRefs(state, d.body, local_map, bound),
        .try_expr => |*t| try rewriteModuleRefs(state, t.expression, local_map, bound),
        .error_expr => |*e| try rewriteModuleRefs(state, e.args[0], local_map, bound),
        .params => |*p| {
            for (p.params) |*param| {
                if (param.type_annotation) |ta| try rewriteModuleRefs(state, ta, local_map, bound);
            }
        },
        .array_type => |*a| try rewriteModuleRefs(state, a.elem, local_map, bound),
        .pointer_type => |*p| try rewriteModuleRefs(state, p.elem, local_map, bound),
        .union_type => |*u| {
            try rewriteModuleRefs(state, u.left, local_map, bound);
            try rewriteModuleRefs(state, u.right, local_map, bound);
        },
        else => {},
    }
}

fn moduleKey(path: []const u8) []const u8 {
    // Match TS: module keys keep the `.lls` suffix (used to distinguish modules from globals).
    return path;
}

fn collectLocal(state: *CompilerState, node: *ast.Node, mod_key: []const u8, map: *std.StringHashMap([]const u8)) ModuleError!void {
    switch (node.*) {
        .function_decl => |f| {
            if (std.mem.indexOf(u8, f.name, "::") == null) {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, f.name });
                try state.owned.append(state.allocator, q);
                try map.put(f.name, q);
            }
        },
        .declaration => |d| {
            if (std.mem.indexOf(u8, d.name, "::") == null) {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, d.name });
                try state.owned.append(state.allocator, q);
                try map.put(d.name, q);
            }
        },
        .struct_decl => |st| {
            if (std.mem.indexOf(u8, st.name, "::") == null) {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, st.name });
                try state.owned.append(state.allocator, q);
                try map.put(st.name, q);
            }
        },
        .enum_decl => |en| {
            if (std.mem.indexOf(u8, en.name, "::") == null) {
                const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_key, en.name });
                try state.owned.append(state.allocator, q);
                try map.put(en.name, q);
            }
        },
        else => {},
    }
}

fn rewriteRefs(node: *ast.Node, local_map: *std.StringHashMap([]const u8)) void {
    switch (node.*) {
        .struct_init => |*s| {
            rewriteRefs(s.type_expr, local_map);
            for (s.fields) |f| rewriteRefs(f.value, local_map);
        },
        .primary => |*p| {
            if (p.kind == .identifier) {
                if (local_map.get(p.name)) |q| p.name = q;
            }
        },
        .binary => |b| {
            rewriteRefs(b.left, local_map);
            rewriteRefs(b.right, local_map);
        },
        .unary => |u| rewriteRefs(u.arg, local_map),
        .call => |c| {
            rewriteRefs(c.callee, local_map);
            for (c.args) |a| rewriteRefs(a, local_map);
        },
        .assignment => |a| {
            rewriteRefs(a.left, local_map);
            rewriteRefs(a.right, local_map);
        },
        .member => |m| {
            rewriteRefs(m.object, local_map);
            // Same as rewriteModuleRefs: do not rewrite member property identifiers.
        },
        .index => |ix| {
            rewriteRefs(ix.object, local_map);
            if (ix.index) |start| rewriteRefs(start, local_map);
            if (ix.end) |end| rewriteRefs(end, local_map);
        },
        .array_literal => |a| {
            for (a.elements) |e| rewriteRefs(e, local_map);
        },
        .block => |b| {
            for (b.statements) |s| rewriteRefs(s, local_map);
        },
        .function_decl => |f| {
            rewriteRefs(f.body, local_map);
        },
        .declaration => |d| rewriteRefs(d.value, local_map),
        .return_expr => |r| {
            if (r.return_value) |v| rewriteRefs(v, local_map);
        },
        .if_expr => |i| {
            rewriteRefs(i.condition, local_map);
            rewriteRefs(i.body, local_map);
            if (i.else_body) |e| rewriteRefs(e, local_map);
        },
        .switch_expr => |sw| {
            rewriteRefs(sw.condition, local_map);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| rewriteRefs(pat, local_map);
                rewriteRefs(prong.body, local_map);
            }
        },
        .break_expr => |br| {
            if (br.value) |v| rewriteRefs(v, local_map);
        },
        .for_expr => |f| {
            rewriteRefs(f.expr, local_map);
            rewriteRefs(f.body, local_map);
        },
        .struct_decl => |st| {
            for (st.methods) |m| rewriteRefs(m, local_map);
        },
        .enum_decl => {},
        .try_expr => |t| rewriteRefs(t.expression, local_map),
        .error_expr => |e| rewriteRefs(e.args[0], local_map),
        else => {},
    }
}
