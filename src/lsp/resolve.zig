//! AST-based name resolution for go-to-definition.
//!
//! Replaces the old "first token after @func/@struct/..." heuristic. Names
//! resolve through the parse tree so shadowing, parameters, and forward
//! references behave like the language, not like text search.
//!
//! Scoping model (mirrors how llts actually resolves names):
//!   1. The innermost enclosing function of the use (found exactly, by node
//!      identity) contributes its parameters and every declaration inside
//!      it; the closest declaration that precedes the use wins. This makes
//!      locals shadow globals and later locals shadow earlier ones.
//!      `$reg` declarations parse as `.declaration` nodes whose name is the
//!      bare register name (the scanner strips `$`), so they are covered.
//!   2. Otherwise, global (top-level) declarations are searched: the closest
//!      preceding one wins, falling back to the first match anywhere to
//!      support forward references.
//!   3. Locals of *other* functions never match — a sibling function's
//!      internals are invisible.

const std = @import("std");
const llts = @import("llts");
const ast = llts.ast;
const infer = @import("infer.zig");

/// Resolve `name` (a token value; identifiers and bare register names are
/// the same shape to the resolver) used at 1-based (line, col) to the
/// location of its declaring site.
pub fn resolveDefinition(doc: *const ast.Document, name: []const u8, line: u32, col: u32) ?ast.Location {
    // 1. Function scope: parameters, then closest preceding local decl.
    if (infer.findPrimaryInDoc(doc, line, col)) |primary| {
        if (innermostFunction(doc, primary)) |func_node| {
            if (func_node.* == .function_decl) {
                const f = func_node.function_decl;
                // Parameters are in scope for the whole body.
                if (f.params.* == .params) {
                    for (f.params.params.params) |p| {
                        if (std.mem.eql(u8, p.name, name)) return p.loc;
                    }
                }
                var best: ?ast.Location = null;
                findNestedBefore(f.body, name, line, col, &best);
                if (best) |b| return b;
            }
        }
    }

    // 2. Globals: closest preceding wins; forward refs fall back to first.
    var before: ?ast.Location = null;
    var first: ?ast.Location = null;
    for (doc.statements) |stmt| {
        const loc = globalDeclLoc(stmt, name) orelse continue;
        if (first == null) first = loc;
        if (locPrecedes(loc, line, col)) {
            if (before == null or locPrecedes(before.?, loc.line, loc.column)) before = loc;
        }
    }
    return before orelse first;
}

fn locPrecedes(loc: ast.Location, line: u32, col: u32) bool {
    return loc.line < line or (loc.line == line and loc.column < col);
}

/// Keep the declaration closest to (but before) the use position.
fn updateBest(best: *?ast.Location, loc: ast.Location, line: u32, col: u32) void {
    if (!locPrecedes(loc, line, col)) return;
    if (best.* == null or locPrecedes(best.*.?, loc.line, loc.column)) best.* = loc;
}

/// Location of a top-level declaration of `name`, if `stmt` declares it.
fn globalDeclLoc(stmt: *ast.Node, name: []const u8) ?ast.Location {
    return switch (stmt.*) {
        .declaration => |d| if (std.mem.eql(u8, d.name, name)) stmt.loc() else null,
        .function_decl => |f| if (std.mem.eql(u8, f.name, name)) stmt.loc() else null,
        .struct_decl => |s| if (std.mem.eql(u8, s.name, name)) stmt.loc() else null,
        .enum_decl => |e| if (std.mem.eql(u8, e.name, name)) stmt.loc() else null,
        .type_decl => |t| if (std.mem.eql(u8, t.name, name)) stmt.loc() else null,
        .error_decl => |e| if (std.mem.eql(u8, e.name, name)) stmt.loc() else null,
        else => null,
    };
}

/// Search a function body for declarations of `name` that precede (line, col),
/// keeping the closest one.
fn findNestedBefore(node: *ast.Node, name: []const u8, line: u32, col: u32, best: *?ast.Location) void {
    switch (node.*) {
        .declaration => |d| {
            if (std.mem.eql(u8, d.name, name)) updateBest(best, node.loc(), line, col);
            findNestedBefore(d.value, name, line, col, best);
        },
        .function_decl => |f| {
            if (std.mem.eql(u8, f.name, name)) updateBest(best, node.loc(), line, col);
            findNestedBefore(f.body, name, line, col, best);
        },
        .struct_decl => |s| {
            if (std.mem.eql(u8, s.name, name)) updateBest(best, node.loc(), line, col);
            for (s.methods) |m| findNestedBefore(m, name, line, col, best);
        },
        .enum_decl => |e| {
            if (std.mem.eql(u8, e.name, name)) updateBest(best, node.loc(), line, col);
        },
        .type_decl => |t| {
            if (std.mem.eql(u8, t.name, name)) updateBest(best, node.loc(), line, col);
        },
        .block => |b| {
            for (b.statements) |s| findNestedBefore(s, name, line, col, best);
        },
        .if_expr => |i| {
            findNestedBefore(i.body, name, line, col, best);
            if (i.else_body) |eb| findNestedBefore(eb, name, line, col, best);
        },
        .for_expr => |f| {
            // Captures bind by name inside the loop body.
            for (f.captures) |c| {
                if (std.mem.eql(u8, c.name, name)) updateBest(best, node.loc(), line, col);
            }
            findNestedBefore(f.body, name, line, col, best);
        },
        .switch_expr => |sw| {
            for (sw.prongs) |p| findNestedBefore(p.body, name, line, col, best);
        },
        .defer_stmt => |d| findNestedBefore(d.body, name, line, col, best),
        // Expressions can nest blocks (if/switch/for-as-expression, labeled
        // blocks); keep walking so a use inside a nested block still sees
        // declarations from enclosing blocks of the same function.
        .binary => |b| {
            findNestedBefore(b.left, name, line, col, best);
            findNestedBefore(b.right, name, line, col, best);
        },
        .call => |c| {
            for (c.args) |arg| findNestedBefore(arg, name, line, col, best);
        },
        .return_expr => |r| {
            if (r.return_value) |v| findNestedBefore(v, name, line, col, best);
        },
        .array_literal => |al| {
            for (al.elements) |el| findNestedBefore(el, name, line, col, best);
        },
        .struct_init => |si| {
            for (si.fields) |f| findNestedBefore(f.value, name, line, col, best);
        },
        .try_expr => |te| findNestedBefore(te.expression, name, line, col, best),
        else => {},
    }
}

/// Innermost function_decl whose body (by node identity) contains `target`.
fn innermostFunction(doc: *const ast.Document, target: *ast.Node) ?*ast.Node {
    for (doc.statements) |stmt| {
        if (innermostFuncIn(stmt, target)) |f| return f;
    }
    return null;
}

fn innermostFuncIn(node: *ast.Node, target: *ast.Node) ?*ast.Node {
    switch (node.*) {
        .function_decl => |f| {
            if (!containsNode(f.body, target)) return null;
            return innermostFuncIn(f.body, target) orelse node;
        },
        .struct_decl => |s| {
            for (s.methods) |m| {
                if (innermostFuncIn(m, target)) |inner| return inner;
            }
            return null;
        },
        .block => |b| {
            for (b.statements) |s| {
                if (innermostFuncIn(s, target)) |inner| return inner;
            }
            return null;
        },
        .declaration => |d| return innermostFuncIn(d.value, target),
        .if_expr => |i| {
            if (innermostFuncIn(i.body, target)) |inner| return inner;
            if (i.else_body) |eb| return innermostFuncIn(eb, target);
            return null;
        },
        .for_expr => |f| return innermostFuncIn(f.body, target),
        .switch_expr => |sw| {
            for (sw.prongs) |p| {
                if (innermostFuncIn(p.body, target)) |inner| return inner;
            }
            return null;
        },
        .defer_stmt => |d| return innermostFuncIn(d.body, target),
        else => return null,
    }
}

/// Exact (pointer identity) subtree containment. Traversal mirrors
/// infer.findPrimaryAtLoc so every node it can return is reachable here.
fn containsNode(node: *ast.Node, target: *ast.Node) bool {
    if (node == target) return true;
    switch (node.*) {
        .declaration => |d| return containsNode(d.value, target),
        .binary => |b| return containsNode(b.left, target) or containsNode(b.right, target),
        .unary => |u| return containsNode(u.arg, target),
        .assignment => |a| return containsNode(a.left, target) or containsNode(a.right, target),
        .call => |c| {
            if (containsNode(c.callee, target)) return true;
            for (c.args) |arg| {
                if (containsNode(arg, target)) return true;
            }
            return false;
        },
        .member => |m| return containsNode(m.object, target) or containsNode(m.property, target),
        .index => |i| {
            if (containsNode(i.object, target)) return true;
            if (i.index) |idx| {
                if (containsNode(idx, target)) return true;
            }
            if (i.end) |end| return containsNode(end, target);
            return false;
        },
        .array_literal => |al| {
            for (al.elements) |el| {
                if (containsNode(el, target)) return true;
            }
            return false;
        },
        .function_decl => |f| return containsNode(f.body, target),
        .struct_decl => |s| {
            for (s.methods) |m| {
                if (containsNode(m, target)) return true;
            }
            return false;
        },
        .block => |b| {
            for (b.statements) |s| {
                if (containsNode(s, target)) return true;
            }
            return false;
        },
        .if_expr => |i| {
            if (containsNode(i.condition, target)) return true;
            if (containsNode(i.body, target)) return true;
            if (i.else_body) |eb| return containsNode(eb, target);
            return false;
        },
        .for_expr => |f| return containsNode(f.expr, target) or containsNode(f.body, target),
        .switch_expr => |s| {
            if (containsNode(s.condition, target)) return true;
            for (s.prongs) |p| {
                if (containsNode(p.body, target)) return true;
                for (p.patterns) |pat| {
                    if (containsNode(pat, target)) return true;
                }
            }
            return false;
        },
        .return_expr => |r| return if (r.return_value) |v| containsNode(v, target) else false,
        .defer_stmt => |d| return containsNode(d.body, target),
        .struct_init => |si| {
            if (containsNode(si.type_expr, target)) return true;
            for (si.fields) |f| {
                if (containsNode(f.value, target)) return true;
            }
            return false;
        },
        .try_expr => |te| return containsNode(te.expression, target),
        .error_expr => |ee| {
            for (ee.args) |arg| {
                if (containsNode(arg, target)) return true;
            }
            return false;
        },
        .pointer_type => |pt| return containsNode(pt.elem, target),
        .array_type => |at| return containsNode(at.elem, target),
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Parsed = struct { doc: ast.Document, tokens: []const llts.scanner.Token };

fn parseDoc(alloc: std.mem.Allocator, src: []const u8) !Parsed {
    const scan = try llts.scanner.scan(alloc, src, "test.lls");
    const doc = try llts.parser.parse(alloc, scan.tokens.items, "test.lls", src, null);
    return .{ .doc = doc, .tokens = scan.tokens.items };
}

/// First token with the given text on a 1-based line — the "use" position,
/// taken straight from the scanner so tests don't hardcode columns.
fn useToken(p: Parsed, text: []const u8, line: u32) llts.scanner.Token {
    for (p.tokens) |t| {
        if (t.line == line and std.mem.eql(u8, t.value, text)) return t;
    }
    unreachable; // test bug: token not on that line
}

test "register local shadows global" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Only `$reg = ...` declares a function-local; a later use of the bare
    // name must resolve to the local, not the global.
    const p = try parseDoc(arena.allocator(),
        \\@const $x = 1;
        \\@func main() {
        \\    $x = 2;
        \\    print(x);
        \\}
        \\
    );
    const t = useToken(p, "x", 4);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 3), loc.line);
}

test "parameter resolves inside function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseDoc(arena.allocator(),
        \\@func add(a, b) {
        \\  return a + b;
        \\}
        \\
    );
    const t = useToken(p, "b", 2);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 1), loc.line);
}

test "global forward reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseDoc(arena.allocator(),
        \\@func main() {
        \\  print(x);
        \\}
        \\@const $x = 1;
        \\
    );
    const t = useToken(p, "x", 2);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 4), loc.line);
}

test "sibling function locals are invisible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseDoc(arena.allocator(),
        \\@func f() { $y = 1; }
        \\@func g() { print(y); }
        \\
    );
    const t = useToken(p, "y", 2);
    try testing.expectEqual(@as(?ast.Location, null), resolveDefinition(&p.doc, t.value, t.line, t.column));
}

test "use before local decl falls back to global" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseDoc(arena.allocator(),
        \\@const $x = 1;
        \\@func main() {
        \\  print(x);
        \\  $x = 2;
        \\}
        \\
    );
    const t = useToken(p, "x", 3);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 1), loc.line);
}

test "identifier assignment does not declare a local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `x = 2` assigns the global (no local is created); the use must resolve
    // to the global declaration.
    const p = try parseDoc(arena.allocator(),
        \\@const $x = 1;
        \\@func main() {
        \\  x = 2;
        \\  print(x);
        \\}
        \\
    );
    const t = useToken(p, "x", 4);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 1), loc.line);
}

test "register declaration resolves use in expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseDoc(arena.allocator(),
        \\@func main() {
        \\  $r = 5;
        \\  print(r);
        \\}
        \\
    );
    const t = useToken(p, "r", 3);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 2), loc.line);
}

test "use on declaration name resolves to itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseDoc(arena.allocator(),
        \\@func extra() {}
        \\
    );
    const t = useToken(p, "extra", 1);
    const loc = resolveDefinition(&p.doc, t.value, t.line, t.column) orelse return error.NoDecl;
    try testing.expectEqual(@as(u32, 1), loc.line);
}
