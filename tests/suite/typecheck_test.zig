const std = @import("std");
const helpers = @import("helpers.zig");

test "typecheck: basic type annotations and inference" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $a: int = 42;
        \\    $b: float = 3.14;
        \\    $c: bool = true;
        \\    $d: string = "hello";
        \\    print(a, b, c, d);
        \\}
    ;
    var state = try helpers.analyzeSource(allocator, src, true);
    defer {
        state.chunk.deinit();
        helpers.compiler.state_mod.deinit(&state);
    }
}

test "typecheck: rejects assigning null to non-optional pointer" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $p: *int = null;
        \\}
    ;
    try helpers.expectCompileFail(allocator, src);
}

test "typecheck: rejects unannotated parameters in strict mode" {
    const allocator = std.testing.allocator;
    const src =
        \\@func add(a, b) {
        \\    return a + b;
        \\}
        \\pub @func main() {
        \\    print(add(1, 2));
        \\}
    ;
    try helpers.expectCompileFail(allocator, src);
}

test "typecheck: rejects missing return path in function" {
    const allocator = std.testing.allocator;
    const src =
        \\@func pick(b: bool): int {
        \\    @if (b) { return 1; }
        \\}
        \\pub @func main() {
        \\    print(pick(true));
        \\}
    ;
    try helpers.expectCompileFail(allocator, src);
}

test "typecheck: rejects invalid member access on partial union without narrowing" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct A { kind: int; x: int; }
        \\@struct B { kind: int; y: int; }
        \\@type V = A | B;
        \\pub @func main() {
        \\    $v: V = A { kind: 0, x: 10 };
        \\    print(v.x);
        \\}
    ;
    try helpers.expectCompileFail(allocator, src);
}

test "typecheck: nominal @type prevents cross-assignment without @as" {
    const allocator = std.testing.allocator;
    const src =
        \\@type UserId = int;
        \\@type OrderId = int;
        \\pub @func main() {
        \\    $u: UserId = 1;
        \\    $o: OrderId = u;
        \\    print(o);
        \\}
    ;
    try helpers.expectCompileFail(allocator, src);
}
