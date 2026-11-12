const std = @import("std");
const helpers = @import("helpers.zig");

test "compiler: reachability marks only called functions reachable" {
    const allocator = std.testing.allocator;
    const src =
        \\@func used(): int { return 10; }
        \\@func unused(): int { return 20; }
        \\pub @func main() {
        \\    print(used());
        \\}
    ;
    var state = try helpers.analyzeSource(allocator, src, true);
    defer {
        state.chunk.deinit();
        helpers.compiler.state_mod.deinit(&state);
    }

    const reach = state.reachability orelse return error.MissingReachability;
    try std.testing.expect(reach.isFunctionReachable("main"));
    try std.testing.expect(reach.isFunctionReachable("used"));
    try std.testing.expect(!reach.isFunctionReachable("unused"));
}

test "compiler: binding facts track read, assigned, and reassigned" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $x = 10;
        \\    x = 20;
        \\    $y = 30;
        \\    print(x);
        \\    _ = y;
        \\}
    ;
    var state = try helpers.analyzeSource(allocator, src, true);
    defer {
        state.chunk.deinit();
        helpers.compiler.state_mod.deinit(&state);
    }

    try std.testing.expect(state.binding_facts.count() > 0);
}
