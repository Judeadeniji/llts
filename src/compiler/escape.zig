const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const widths = @import("widths.zig");

const compile_errors = @import("../errors/compile.zig");

const CompilerState = state_mod.CompilerState;
const AllocRegion = state_mod.AllocRegion;

/// Escape policy: frame-local heap must not outlive its frame.
///
/// Returning a **frame-bound local** of a *deep-cloneable struct* (scalars,
/// enums, nested value-structs) auto-clones it into immortal storage (value
/// semantics — no allocator needed). Nested structs get an unrolled post-order
/// deep clone. Every other frame-bound return is a compile error. Returning a
/// bare `Foo{…}` / `[…]` **literal** whose fields/elements are not frame-colored
/// is allowed: the return site compiles it immortal (see `compileReturn`),
/// matching module-level init. Use `@new(allocator, T)` when a value with
/// pointer/slice fields should live in a reclaimable arena.
pub fn checkReturnValue(state: *CompilerState, value: *ast.Node) !void {
    if (canPromoteReturnLiteral(state, value)) return;
    switch (regionOf(state, value)) {
        .frame => {
            if (canAutoCloneReturn(state, value)) return;
            return failEscape(state, value,
                "value escapes its frame region; deep-cloneable structs clone automatically on return — pointer/slice fields need @new(allocator, T) in an arena that outlives the call");
        },
        .arena_local => return failEscape(state, value,
            "value escapes its arena region; the arena is local to this function — pass the arena in as a parameter or use an allocator that outlives the call"),
        .pass, .unknown => {},
    }
}

/// True when `return <value>` may auto-clone a frame-bound binding into
/// immortal storage. Applies to struct-typed identifiers whose fields are all
/// scalar or nested value-structs (deep-cloneable). Pointer/slice/string
/// fields are rejected — deep-cloning through a pointer needs runtime cycle
/// detection (VM work), and sharing would leave dangling handles.
pub fn canAutoCloneReturn(state: *CompilerState, value: *ast.Node) bool {
    if (regionOf(state, value) != .frame) return false;
    if (value.* != .primary) return false;
    const p = value.primary;
    if (p.kind != .identifier and p.kind != .register) return false;
    const idx = resolveLocalIndex(state, p.name) orelse return false;
    const tn = state.locals.items[idx].type_name orelse return false;
    return isDeepCloneableStruct(state, tn, 0);
}

/// True when display name `tn` resolves to a struct whose fields are all
/// deep-cloneable: scalar widths / bool / enums / scalar typedefs, or nested
/// value-structs (recursively). Depth-limited; cycles cannot occur through
/// value-struct fields (they're stored by handle, and a struct can't contain
/// itself by value), but the guard is cheap insurance.
pub fn isDeepCloneableStruct(state: *CompilerState, tn: []const u8, depth: u8) bool {
    if (depth > 8) return false;
    const sd = state.structs.get(tn) orelse return false;
    var it = sd.types.iterator();
    while (it.next()) |e| {
        if (!isDeepCloneableFieldType(state, e.value_ptr.*, depth)) return false;
    }
    return true;
}

/// True when `tn` has at least one nested value-struct field (requiring deep
/// clone rather than a flat shallow copy).
pub fn hasNestedStructFields(state: *CompilerState, tn: []const u8) bool {
    const sd = state.structs.get(tn) orelse return false;
    var it = sd.types.iterator();
    while (it.next()) |e| {
        if (state.structs.contains(e.value_ptr.*)) return true;
    }
    return false;
}

fn isDeepCloneableFieldType(state: *CompilerState, disp: []const u8, depth: u8) bool {
    if (widths.fromName(disp) != null) return true;
    if (state.enums.contains(disp)) return true;
    // Enum variant literal display `Enum.Variant`.
    if (std.mem.lastIndexOfScalar(u8, disp, '.')) |dot| {
        if (state.enums.contains(disp[0..dot])) return true;
    }
    // Scalar typedef chain (`@type UserId = i64`).
    if (state.typedefs.get(disp)) |td| {
        if (td.underlying.len > 0) return isDeepCloneableFieldType(state, td.underlying, depth + 1);
        return false;
    }
    // Nested value-struct — recursive deep-clone.
    if (state.structs.contains(disp)) return isDeepCloneableStruct(state, disp, depth + 1);
    // Pointer / slice / string / function / shape — not deep-cloneable compiler-only.
    return false;
}

/// Emit an escape diagnostic at the value's source location.
fn failEscape(state: *CompilerState, value: *ast.Node, comptime msg: []const u8) error{CompileError} {
    const loc = value.loc();
    const path = if (loc.path.len > 0) loc.path else state.chunk.file;
    const source = if (std.mem.eql(u8, path, state.chunk.file)) state.chunk.source else blk: {
        for (state.chunk.sources.items) |s| {
            if (std.mem.eql(u8, s.path, path)) break :blk s.text;
        }
        break :blk state.chunk.source;
    };
    return compile_errors.compileFailAt(
        state,
        path,
        source,
        loc.line,
        loc.column,
        msg,
        .{},
    );
}

/// True when `return <value>` can immortalize a literal shell instead of erroring.
pub fn canPromoteReturnLiteral(state: *CompilerState, value: *ast.Node) bool {
    switch (value.*) {
        .struct_init => |*init| {
            for (init.fields) |f| {
                if (!operandOkForPromote(state, f.value)) return false;
            }
            return true;
        },
        .array_literal => |*arr| {
            for (arr.elements) |el| {
                if (!operandOkForPromote(state, el)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn operandOkForPromote(state: *CompilerState, node: *ast.Node) bool {
    switch (node.*) {
        .struct_init, .array_literal => return canPromoteReturnLiteral(state, node),
        else => return regionOf(state, node) != .frame,
    }
}

/// Classify an expression's heap region (syntactic / local-tracking first cut).
pub fn regionOf(state: *CompilerState, node: *ast.Node) AllocRegion {
    switch (node.*) {
        // Bare literals → frame bump; immortal only for module-level inits / return promotion.
        .struct_init, .array_literal => return if (state.alloc_immortal) .pass else .frame,
        // `@new(a, Foo{…})` — compiler intrinsic. The result inherits the
        // lifetime of its allocator (Phase 4.1): an arena owned by a body-local
        // cannot outlive the frame, but an arena passed in (or any other
        // allocator we cannot prove local) may escape.
        .call => |c| {
            if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@new")) {
                if (c.args.len > 0 and allocatorIsFunctionLocal(state, c.args[0])) return .arena_local;
                return .pass;
            }
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

/// True when `node` directly names a local of the *current function body*
/// (not a parameter, not a module-level binding). Such a local — typically an
/// `Arena` from `mem.create(...)` — is unreachable once the function returns,
/// so memory allocated from it is frame-bound.
fn allocatorIsFunctionLocal(state: *CompilerState, node: *ast.Node) bool {
    if (node.* != .primary) return false;
    const p = node.primary;
    if (p.kind != .identifier and p.kind != .register) return false;
    const idx = resolveLocalIndex(state, p.name) orelse return false;
    return !state.locals.items[idx].is_param;
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
