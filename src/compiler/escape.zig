const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");

const CompilerState = state_mod.CompilerState;
const AllocRegion = state_mod.AllocRegion;

/// Escape policy: frame-local heap must not outlive its frame.
/// Returning it is a **compile error** (no silent promote / no UAF).
/// Use `@new(allocator, Foo{…})` so the value is born in a Pass arena.
pub fn checkReturnValue(state: *CompilerState, value: *ast.Node) !void {
    switch (regionOf(state, value)) {
        .frame => {
            const loc = value.loc();
            const path = if (loc.path.len > 0) loc.path else state.chunk.file;
            const source = if (std.mem.eql(u8, path, state.chunk.file)) state.chunk.source else blk: {
                for (state.chunk.sources.items) |s| {
                    if (std.mem.eql(u8, s.path, path)) break :blk s.text;
                }
                break :blk state.chunk.source;
            };
            return @import("../errors/compile.zig").compileFailAt(
                state,
                path,
                source,
                loc.line,
                loc.column,
                "value escapes its frame region; allocate with @new(allocator, …)",
                .{},
            );
        },
        .pass, .unknown => {},
    }
}

/// Classify an expression's heap region (syntactic / local-tracking first cut).
pub fn regionOf(state: *CompilerState, node: *ast.Node) AllocRegion {
    switch (node.*) {
        // Bare literals → frame bump; immortal only for module-level inits (`alloc_immortal`).
        .struct_init, .array_literal => return if (state.alloc_immortal) .pass else .frame,
        // `@new(a, Foo{…})` — compiler intrinsic; Pass / outer allocator.
        .call => |c| {
            if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@new"))
                return .pass;
            return .unknown;
        },
        .primary => |p| {
            if (p.kind != .identifier and p.kind != .register) return .unknown;
            const idx = resolveLocalIndex(state, p.name);
            if (idx) |i| return state.locals.items[i].alloc_region;
            return .unknown;
        },
        // `error(…)` is immortal at runtime — treat as non-frame.
        .error_expr => return .pass,
        .unary => |u| {
            if (std.mem.eql(u8, u.operator, "&")) return regionOf(state, u.arg);
            return .unknown;
        },
        else => return .unknown,
    }
}

pub fn regionOfRhs(state: *CompilerState, node: *ast.Node) AllocRegion {
    return regionOf(state, node);
}

fn resolveLocalIndex(state: *CompilerState, name: []const u8) ?usize {
    var i: isize = @intCast(state.locals.items.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const local = state.locals.items[@intCast(i)];
        if (std.mem.eql(u8, local.name, name)) return @intCast(i);
    }
    return null;
}

pub fn markLocalRegion(state: *CompilerState, name: []const u8, region: AllocRegion) void {
    if (resolveLocalIndex(state, name)) |i| {
        state.locals.items[i].alloc_region = region;
    }
}
