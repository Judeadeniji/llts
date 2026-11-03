const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const types = @import("typecheck/from_ast.zig");

const CompilerState = state_mod.CompilerState;

/// Builtin to shallow-clone `node` on assign/decl, or `null` when the value
/// should share (scalars, pointers, or unknown types).
///
/// Value semantics: bare structs, arrays, `[]byte` / `[N]byte`, and `string`
/// copy on assign. Sharing requires an explicit `*T` / `&x`.
pub fn cloneBuiltin(state: *CompilerState, node: *ast.Node) ?[]const u8 {
    switch (node.*) {
        .primary, .member => {},
        else => return null,
    }
    const tn = types.resolveType(state, node) orelse return null;
    const trimmed = std.mem.trim(u8, tn, " \t");
    // Pointers and optionals share handles by design.
    if (trimmed.len > 0 and (trimmed[0] == '*' or trimmed[0] == '?')) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '*') != null) return null;
    if (std.mem.indexOf(u8, trimmed, " | null") != null) return null;

    if (types.lookupStruct(state, trimmed) != null) return "__cloneBytes";
    if (isByteSpanDisplay(trimmed)) return "__cloneBytes";
    if (trimmed.len > 0 and trimmed[0] == '[') return "__cloneArray";
    return null;
}

fn isByteSpanDisplay(disp: []const u8) bool {
    if (std.mem.eql(u8, disp, "string")) return true;
    if (std.mem.eql(u8, disp, "[]byte") or std.mem.eql(u8, disp, "[]u8")) return true;
    if (disp.len > 0 and disp[0] == '[') {
        if (std.mem.endsWith(u8, disp, "]byte") or std.mem.endsWith(u8, disp, "]u8")) return true;
    }
    return false;
}
