const std = @import("std");
const helpers = @import("helpers.zig");

test "pipeline: string switch emits rt.arith.eqStr" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $s = "test";
        \\    @switch (s) {
        \\        "test" => { print(1); },
        \\        @else => { print(0); },
        \\    }
        \\}
    ;
    try helpers.expectEmitContains(allocator, src, "rt.arith.eqStr");
}

test "pipeline: rest parameters pack into stack slice" {
    const allocator = std.testing.allocator;
    const src =
        \\@func sum(first: int, ...rest: []int): int {
        \\    $acc = first;
        \\    @for (rest) |x| { acc = acc + x; }
        \\    return acc;
        \\}
        \\pub @func main() {
        \\    print(sum(1, 2, 3));
        \\}
    ;
    try helpers.expectEmitContains(allocator, src, "&[_]i64{");
    try helpers.expectEmitContains(allocator, src, "[]const i64");
}

test "pipeline native execution: control flow and defer LIFO" {
    const allocator = std.testing.allocator;
    const src =
        \\@func compute(): int {
        \\    defer print("cleanup 1");
        \\    defer print("cleanup 2");
        \\    return 42;
        \\}
        \\pub @func main() {
        \\    $r = compute();
        \\    print(r);
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "cleanup 2\ncleanup 1\n42\n");
}

test "pipeline native execution: structs formatted as Node.js objects" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Point { x: int; y: int; }
        \\pub @func main() {
        \\    $p = Point { x: 10, y: 20 };
        \\    print(p);
        \\}
    ;
    const expected =
        \\Point {
        \\  x: 10,
        \\  y: 20,
        \\}
        \\
    ;
    try helpers.expectNativeStdout(allocator, src, expected);
}
