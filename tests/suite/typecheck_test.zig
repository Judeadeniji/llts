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
    var analyzed = try helpers.analyzeSource(allocator, src, true);
    defer analyzed.deinit();
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

test "typecheck: closure type inference and capture tracking" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $multiplier: int = 10;
        \\    $f = @func(x: int): int {
        \\        return x * multiplier;
        \\    };
        \\    print(f(5));
        \\}
    ;
    var analyzed = try helpers.analyzeSource(allocator, src, true);
    defer analyzed.deinit();

    try std.testing.expectEqual(@as(usize, 1), analyzed.state.closures.count());
    var it = analyzed.state.closures.valueIterator();
    const info = it.next().?;
    try std.testing.expectEqual(@as(usize, 1), info.captures.len);
    try std.testing.expectEqualStrings("multiplier", info.captures[0].name);
    try std.testing.expectEqual(false, info.captures[0].is_mutated);
}

test "typecheck: closure with mutated capture" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $counter: int = 0;
        \\    $inc = @func() {
        \\        counter = counter + 1;
        \\    };
        \\    inc();
        \\}
    ;
    var analyzed = try helpers.analyzeSource(allocator, src, true);
    defer analyzed.deinit();

    try std.testing.expectEqual(@as(usize, 1), analyzed.state.closures.count());
    var it = analyzed.state.closures.valueIterator();
    const info = it.next().?;
    try std.testing.expectEqual(@as(usize, 1), info.captures.len);
    try std.testing.expectEqualStrings("counter", info.captures[0].name);
    try std.testing.expectEqual(true, info.captures[0].is_mutated);
}

test "typecheck: method with a type parameter before 'self' is rejected, not a crash" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@struct Runner {
        \\    tag: int;
        \\
        \\    @func apply(F: type, self, f: F, x: int): int {
        \\        return f(x);
        \\    }
        \\}
        \\pub @func main() {
        \\    $r: Runner = { tag: 0 };
        \\    print(r.apply(Fn, @func(v: int): int { return v; }, 14));
        \\}
    ;
    try helpers.expectCompileFail(allocator, src);
}
