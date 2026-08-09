const std = @import("std");
const state_mod = @import("state.zig");
const ast = @import("../ast/root.zig");
const scanner = @import("../scanner/root.zig");
const parser = @import("../parser/root.zig");

const CompilerState = state_mod.CompilerState;
const ModuleError = error{ OutOfMemory, CompileError };

/// Resolve `@import` nodes: load, parse, and qualify public decls into `doc`.
pub fn resolveImports(state: *CompilerState, doc: *ast.Document) ModuleError!void {
    var visited = std.StringHashMap(void).init(state.allocator);
    defer visited.deinit();
    try resolveImportsInner(state, doc, null, &visited);
}

fn resolveImportsInner(
    state: *CompilerState,
    doc: *ast.Document,
    current_module: ?[]const u8,
    visited: *std.StringHashMap(void),
) ModuleError!void {
    var has_import = false;
    for (doc.statements) |s| {
        if (s.* == .import) {
            has_import = true;
            break;
        }
        if (s.* == .declaration and s.declaration.value.* == .import) {
            has_import = true;
            break;
        }
    }
    if (!has_import) return;

    var out: std.ArrayList(*ast.Node) = .empty;
    defer out.deinit(state.allocator);

    for (doc.statements) |s| {
        switch (s.*) {
            .import => |imp| {
                try loadModule(state, doc, imp.import_path, null, current_module, &out, visited);
            },
            .declaration => |d| {
                if (d.value.* == .import) {
                    try loadModule(state, doc, d.value.import.import_path, d.name, current_module, &out, visited);
                } else {
                    try out.append(state.allocator, s);
                }
            },
            else => try out.append(state.allocator, s),
        }
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

    const source = std.fs.cwd().readFileAlloc(state.allocator, resolved, 16 * 1024 * 1024) catch {
        std.debug.print("CompileError: cannot read import '{s}'\n", .{resolved});
        return error.CompileError;
    };
    try state.owned.append(state.allocator, source);

    var scan_result = scanner.scan(state.allocator, source, resolved) catch return error.CompileError;
    defer scanner.deinitScanResult(&scan_result);

    const mod_doc = parser.parse(state.allocator, scan_result.tokens.items, resolved, source) catch return error.CompileError;
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
        return with_ext;
    } else |_| {}

    // 2. parent of cwd (zig/ → repo root)
    const up = try std.fmt.allocPrint(state.allocator, "../{s}", .{with_ext});
    if (std.fs.cwd().access(up, .{})) |_| {
        state.allocator.free(with_ext);
        return up;
    } else |_| {
        state.allocator.free(up);
    }

    // 3. relative to importer
    const dir = std.fs.path.dirname(from) orelse ".";
    const joined = try std.fs.path.join(state.allocator, &.{ dir, with_ext });
    state.allocator.free(with_ext);
    if (std.fs.cwd().access(joined, .{})) |_| {
        return joined;
    } else |_| {}

    std.debug.print("CompileError: Unknown module '{s}'\n", .{import_path});
    state.allocator.free(joined);
    return error.CompileError;
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
                    if (p.* == .declaration) try bound.append(state.allocator, p.declaration.name);
                    if (p.* == .primary) try bound.append(state.allocator, p.primary.name);
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
            if (local_map.get(init.name)) |q| {
                if (!boundContains(bound, init.name)) init.name = q;
            }
            for (init.fields) |field| try rewriteModuleRefs(state, field.value, local_map, bound);
        },
        .for_expr => |*f| {
            if (f.condition) |c| try rewriteModuleRefs(state, c, local_map, bound);
            if (f.range_start) |s| try rewriteModuleRefs(state, s, local_map, bound);
            if (f.range_end) |e| try rewriteModuleRefs(state, e, local_map, bound);
            if (f.iterable) |it| try rewriteModuleRefs(state, it, local_map, bound);
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
            try rewriteModuleRefs(state, m.property, local_map, bound);
        },
        .index => |*ix| {
            try rewriteModuleRefs(state, ix.object, local_map, bound);
            try rewriteModuleRefs(state, ix.index, local_map, bound);
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
        .error_expr => |*e| try rewriteModuleRefs(state, e.message, local_map, bound),
        .params => |*p| {
            for (p.params) |param| try rewriteModuleRefs(state, param, local_map, bound);
        },
        .array_type, .union_type => {},
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
        else => {},
    }
}

fn rewriteRefs(node: *ast.Node, local_map: *std.StringHashMap([]const u8)) void {
    switch (node.*) {
        .struct_init => |*s| {
            if (local_map.get(s.name)) |q| s.name = q;
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
            rewriteRefs(m.property, local_map);
        },
        .index => |ix| {
            rewriteRefs(ix.object, local_map);
            rewriteRefs(ix.index, local_map);
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
        .for_expr => |f| {
            if (f.condition) |c| rewriteRefs(c, local_map);
            if (f.range_start) |s| rewriteRefs(s, local_map);
            if (f.range_end) |e| rewriteRefs(e, local_map);
            if (f.iterable) |it| rewriteRefs(it, local_map);
            rewriteRefs(f.body, local_map);
        },
        .struct_decl => |st| {
            for (st.methods) |m| rewriteRefs(m, local_map);
        },
        .try_expr => |t| rewriteRefs(t.expression, local_map),
        .error_expr => |e| rewriteRefs(e.message, local_map),
        else => {},
    }
}
