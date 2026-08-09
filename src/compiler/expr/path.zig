const std = @import("std");
const ast = @import("../../ast/root.zig");
const state_mod = @import("../state.zig");

const CompilerState = state_mod.CompilerState;

/// Resolve `lib.Vector3` → `examples/import_test_lib::Vector3` via `$lib` → `module:…`.
pub fn resolveModuleType(state: *CompilerState, type_name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, type_name, '.')) |dot| {
        const mod_alias = type_name[0..dot];
        const short = type_name[dot + 1 ..];
        var buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "${s}", .{mod_alias});
        if (state.global_types.get(key)) |mod| {
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
            var buf: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "${s}", .{p.name});
            if (state.global_types.get(key)) |mod| {
                if (std.mem.startsWith(u8, mod, "module:")) return mod["module:".len..];
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
            const q = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ obj_path, prop });
            try state.owned.append(state.allocator, q);
            return q;
        },
        else => return null,
    }
}
