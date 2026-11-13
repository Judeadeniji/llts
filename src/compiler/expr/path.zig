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

/// Global-binding key for an alias, scoped to the importing module when
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
        if (state.global_type_irs.contains(scoped)) return scoped;
    }
    return bareAliasKey(buf, alias);
}

fn bareAliasKey(buf: []u8, alias: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "${s}", .{alias}) catch "";
}

/// The `module:…` marker for a global binding, read from canonical IR.
pub fn moduleBindingType(state: *CompilerState, key: []const u8) ?[]const u8 {
    const t = state.global_type_irs.get(key) orelse return null;
    if (t == .struct_ and std.mem.startsWith(u8, t.struct_, "module:")) return t.struct_;
    return null;
}

/// Alias → `module:…` marker, preferring the scoped binding of the module being
/// compiled over the bare (last-import-wins) binding. Nested modules bind
/// aliases under bare keys too, so two modules may share one bare key; without
/// scoping the last import silently wins.
pub fn aliasModuleType(state: *CompilerState, alias: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const key = moduleAliasMapKey(state, &buf, alias);
    return moduleBindingType(state, key);
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

/// True when `<mod_path>::<member>` is a declared module-level *mutable* global
/// (`pub $name = …`). That export is the one namespace member another module is
/// allowed to assign through the module name (`internal.defaultOutput = bridge`);
/// functions, types, constants, submodules and undeclared names are read-only.
pub fn moduleMemberIsMutableGlobal(state: *CompilerState, mod_path: []const u8, member: []const u8) bool {
    if (member.len == 0 or mod_path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, member, ':') != null) return false;
    var buf: [512]u8 = undefined;
    if (isMutableGlobalKey(state, &buf, mod_path, member)) return true;
    // Module keys are recorded with the `.lls` suffix; accept the extensionless
    // form too so callers that resolved a module by name still match.
    if (std.mem.endsWith(u8, mod_path, ".lls")) {
        var ebuf: [512]u8 = undefined;
        return isMutableGlobalKey(state, &ebuf, mod_path[0 .. mod_path.len - 4], member);
    }
    return false;
}

fn isMutableGlobalKey(state: *CompilerState, buf: []u8, mod_path: []const u8, member: []const u8) bool {
    const key = std.fmt.bufPrint(buf, "{s}::{s}", .{ mod_path, member }) catch return false;
    return state.global_vars.contains(key) and !state.global_consts.contains(key);
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
            if (moduleBindingType(state, re_key)) |re| return re["module:".len..];
            // `mod.value.field` — once `mod.value` is a typed binding (not a nested module),
            // further members are fields/methods, not static path segments.
            if (state.global_type_irs.get(obj_path)) |obj_ty| {
                const is_module = obj_ty == .struct_ and std.mem.startsWith(u8, obj_ty.struct_, "module:");
                if (!is_module) return null;
            }
            const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ obj_path, prop });
            try state.owned.append(state.allocator, q);
            return q;
        },
        else => return null,
    }
}
