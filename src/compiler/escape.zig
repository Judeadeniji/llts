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
            std.debug.print(
                \\CompileError: value escapes its frame region
                \\  --> {s}:{d}:{d}
                \\  help: allocate with @new(allocator, …) so it lives in a Pass arena
                \\
            ,
                .{ state.chunk.file, loc.line, loc.column },
            );
            return error.CompileError;
        },
        .pass, .unknown => {},
    }
}

/// Classify an expression's heap region (syntactic / local-tracking first cut).
pub fn regionOf(state: *CompilerState, node: *ast.Node) AllocRegion {
    switch (node.*) {
        // Bare literals → current frame bump (VM rewinds on return).
        .struct_init, .array_literal => return .frame,
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
