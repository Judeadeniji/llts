const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");
const modules = @import("../modules.zig");
const scope = @import("../scope.zig");
const CompilerState = state_mod.CompilerState;

/// Path of the module whose code is currently being compiled.
/// `diag_path` is maintained per-node during typecheck (`noteDiag`) and emit
/// (`noteLoc`); the root document has no scoped alias context.
pub fn currentModulePath(state: *CompilerState) []const u8 {
    if (state.diag_path.len > 0) return state.diag_path;
    return state.chunk.file;
}

/// `global_types` key for an alias binding, scoped to the importing module when
/// the code being compiled belongs to one (`$mod::alias`), else the bare key
/// (`$alias`) used by root-document imports.
pub fn moduleAliasMapKey(
    state: *CompilerState,
    buf: []u8,
    alias: []const u8,
) []const u8 {
    const mod = currentModulePath(state);
    if (std.mem.indexOfScalar(u8, mod, ':') == null and mod.len > 0 and state.chunk.file.len > 0 and !std.mem.eql(u8, mod, state.chunk.file)) {
        const scoped = std.fmt.bufPrint(buf, "${s}::{s}", .{ mod, alias }) catch return bareAliasKey(buf, alias);
        if (state.global_types.contains(scoped)) return scoped;
    }
    return bareAliasKey(buf, alias);
}

fn bareAliasKey(buf: []u8, alias: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "${s}", .{alias}) catch "";
}

/// Alias → `module:…` value from `global_types`, preferring the scoped binding of
/// the module being compiled over the bare (last-import-wins) binding.
/// Nested modules bind aliases under bare keys too, so two modules may share one
/// bare key; without scoping the last import silently wins.
pub fn aliasModuleType(state: *CompilerState, alias: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const key = moduleAliasMapKey(state, &buf, alias);
    return state.global_types.get(key);
}

/// Resolve `lib.Vector3` → `examples/import_test_lib::Vector3` via `$lib` → `module:…`.
pub fn resolveModuleType(state: *CompilerState, type_name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, type_name, '.')) |dot| {
        const mod_alias = type_name[0..dot];
        const short = type_name[dot + 1 ..];
        if (aliasModuleType(state, mod_alias)) |mod| {
            if (std.mem.startsWith(u8, mod, "module:")) {
                const mod_path = mod["module:".len..];
                const qualified = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ mod_path, short });
                try state.owned.append(state.allocator, qualified);
                return qualified;
            }
        }
    }
    return type_name;
}

pub fn tryResolveStaticPath(state: *CompilerState, node: *ast.Node) !?[]const u8 {
    switch (node.*) {
        .primary => |p| {
            if (p.kind != .identifier) return null;
            if (scope.resolveLocal(state, p.name) != -1) return null;
            if (aliasModuleType(state, p.name)) |mod| {
                if (std.mem.startsWith(u8, mod, "module:")) return mod["module:".len..];
            }
            return null;
        },
        .call => |c| {
            if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@import")) {
                if (c.args.len == 1 and c.args[0].* == .literal and c.args[0].literal.literal_type == .string) {
                    const from = if (state.diag_path.len > 0) state.diag_path else state.chunk.file;
                    return modules.resolveImportKey(state, from, c.args[0].literal.value) catch null;
                }
            }
            return null;
        },
        .member => |m| {
            const obj_path = try tryResolveStaticPath(state, m.object) orelse return null;
            if (m.property.* != .primary) return null;
            const prop = m.property.primary.name;
            var buf: [512]u8 = undefined;
            const re_key = std.fmt.bufPrint(&buf, "${s}::{s}", .{ obj_path, prop }) catch return null;
            if (state.global_types.get(re_key)) |re| {
                if (std.mem.startsWith(u8, re, "module:")) return re["module:".len..];
            }
            // `mod.value.field` — once `mod.value` is a typed binding (not a nested module),
            // further members are fields/methods, not static path segments.
            if (state.global_types.get(obj_path)) |obj_ty| {
                if (!std.mem.startsWith(u8, obj_ty, "module:")) return null;
            }
            const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ obj_path, prop });
            try state.owned.append(state.allocator, q);
            return q;
        },
        else => return null,
    }
}
