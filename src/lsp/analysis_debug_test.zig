const std = @import("std");
const analysis = @import("analysis.zig");
const infer = @import("infer.zig");
const handlers = @import("handlers.zig");

test "typecheck failure is captured as tc_diagnostic" {
    const allocator = std.testing.allocator;
    const src =
        \\@func take(x: i32) {}
        \\@func main() {
        \\    take("str");
        \\}
        \\
    ;
    const a = try analysis.create(allocator, "file:///t.lls", src);
    defer {
        a.deinit();
        allocator.destroy(a);
    }
    try analysis.analyzeInPlace(a, 1);

    try std.testing.expectEqual(@as(usize, 0), a.doc.diagnostics.len);
    const tc = a.tc_diagnostic orelse return error.TestUnexpectedResult;
    // 1-based compiler location of the `"str"` argument.
    try std.testing.expectEqual(@as(u32, 3), tc.line);
    try std.testing.expectEqual(@as(u32, 10), tc.column);
    try std.testing.expect(std.mem.indexOf(u8, tc.message, "not assignable") != null);
    // Typecheck state is still available for hover despite the error.
    try std.testing.expect(a.typecheck_state != null);
}

test "member hover resolves in all contexts (call arg, assert, assignment LHS)" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Point {
        \\    x: i64;
        \\    y: i64;
        \\}
        \\$p = Point { x: 10, y: 20 };
        \\std.debug.assert(p.x == 10);
        \\p.x = 42;
        \\
    ;
    const a = try analysis.create(allocator, "file:///mem.lls", src);
    defer {
        a.deinit();
        allocator.destroy(a);
    }
    _ = analysis.analyzeInPlace(a, 1) catch {};

    const state = a.typecheck_state orelse return error.TestUnexpectedResult;
    const doc = &a.doc;

    // Positions are 1-based (token coordinates), matching the handlers.
    // `x` property of `p.x` inside the assert call argument: line 6, col 20.
    const assert_x = infer.findPrimaryInDoc(doc, 6, 20);
    try std.testing.expect(assert_x != null);
    try std.testing.expect(assert_x.?.* == .member);
    try std.testing.expectEqualStrings("x", assert_x.?.member.property.primary.name);
    const assert_ty = state.type_of_results.get(assert_x.?);
    try std.testing.expect(assert_ty != null);
    try std.testing.expect(!std.mem.eql(u8, assert_ty.?, "unknown"));

    // `x` on the assignment LHS (`p.x = 42`): line 7, col 3.
    const lhs_x = infer.findPrimaryInDoc(doc, 7, 3);
    try std.testing.expect(lhs_x != null);
    try std.testing.expect(lhs_x.?.* == .member);
    const lhs_ty = state.type_of_results.get(lhs_x.?);
    try std.testing.expect(lhs_ty != null);
    try std.testing.expectEqualStrings("i64", lhs_ty.?);
}

test "hover: enum/error decl-site variants and error-set formatting" {
    const allocator = std.testing.allocator;
    const src =
        \\@enum Color {
        \\    Red,
        \\    Green,
        \\}
        \\
        \\@error IoError {
        \\    NotFound,
        \\    PermissionDenied,
        \\}
        \\
    ;
    const a = try analysis.create(allocator, "file:///eh.lls", src);
    defer {
        a.deinit();
        allocator.destroy(a);
    }
    _ = analysis.analyzeInPlace(a, 1) catch {};

    var hover_arena = std.heap.ArenaAllocator.init(allocator);
    defer hover_arena.deinit();
    const ha = hover_arena.allocator();

    // Decl-site variant hovers (1-based token coords; Red on line 2, col 5).
    const red = handlers.computeHoverForTest(a, ha, 2, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, red, "(@enum Color) Red = 0") != null);

    const not_found = handlers.computeHoverForTest(a, ha, 7, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, not_found, "(@error IoError) NotFound") != null);

    // The error-set type name renders the full member list (not `Name: @error Name`).
    const io_err = handlers.computeHoverForTest(a, ha, 6, 9) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, io_err, "@error IoError { NotFound, PermissionDenied }") != null);
    try std.testing.expect(std.mem.indexOf(u8, io_err, "IoError: @error") == null);

    // Variant-site finder directly.
    const site = infer.findVariantSiteInDoc(&a.doc, "PermissionDenied", 8) orelse return error.TestUnexpectedResult;
    try std.testing.expect(site.decl_kind == .error_decl);
    try std.testing.expectEqualStrings("IoError", site.type_name);
}

test "position lookup ignores statements inlined from imported modules" {
    const allocator = std.testing.allocator;
    // The `$std` import makes resolveImports splice module statements (with
    // the module's own path/lines) into doc.statements; position lookups in
    // *this* document must not match them.
    const src =
        \\@const $std = @import("std/index");
        \\
        \\@struct P {
        \\    x: i64;
        \\}
        \\$q = P { x: 1 };
        \\
    ;
    const a = try analysis.create(allocator, "file:///imp.lls", src);
    defer {
        a.deinit();
        allocator.destroy(a);
    }
    _ = analysis.analyzeInPlace(a, 1) catch {};

    const doc = &a.doc;
    // Line 5 has only `$q = P { x: 1 };` in *this* file — a lookup there must
    // not hit a module statement whose own line 5 is unrelated.
    const found = infer.findPrimaryInDoc(doc, 5, 1);
    if (found) |node| {
        // Acceptable only if it really is the `$q` member/primary from our file.
        const ok = (node.* == .primary and std.mem.eql(u8, node.primary.name, "$q")) or
            (node.* == .member);
        try std.testing.expect(ok);
    }
}
