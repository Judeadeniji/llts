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

test "pipeline native execution: downward closure passed as argument" {
    const allocator = std.testing.allocator;
    const src =
        \\@func apply(x: int, f: @func(int): int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    $multiplier: int = 10;
        \\    $res = apply(5, @func(v: int): int {
        \\        return v * multiplier;
        \\    });
        \\    print(res);
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "50\n");
}

test "pipeline native execution: returning closure from function (escaping / currying)" {
    const allocator = std.testing.allocator;
    const src =
        \\@func makeAdder(base: int): @func(int): int {
        \\    return @func(v: int): int {
        \\        return base + v;
        \\    };
        \\}
        \\pub @func main() {
        \\    $add10 = makeAdder(10);
        \\    print(add10(5));
        \\    print(add10(20));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "15\n30\n");
}

test "pipeline native execution: closure with shared mutable state" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $counter: int = 0;
        \\    $inc = @func(): int {
        \\        counter = counter + 1;
        \\        return counter;
        \\    };
        \\    print(inc());
        \\    print(inc());
        \\    print(counter);
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "1\n2\n2\n");
}

test "pipeline native execution: top-level function passed to @func argument" {
    const allocator = std.testing.allocator;
    const src =
        \\@func double(x: int): int {
        \\    return x * 2;
        \\}
        \\@func apply(x: int, f: @func(int): int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    print(apply(21, double));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "42\n");
}

test "pipeline native execution: locally devirtualized closure call" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $factor: int = 4;
        \\    $quad = @func(x: int): int {
        \\        return x * factor;
        \\    };
        \\    print(quad(10));
        \\    print(quad(25));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "40\n100\n");
}

test "emitter: non-escaping closure keeps its environment on the stack" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $factor: int = 4;
        \\    $quad = @func(x: int): int {
        \\        return x * factor;
        \\    };
        \\    print(quad(10));
        \\}
    ;
    try helpers.expectEmitContains(allocator, src, "lls_env_stack_");
    try helpers.expectEmitOmits(allocator, src, "allocImmortal(");
}

test "emitter: generic instance calls its bound closure trampoline directly" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@func apply(F: type, f: F, x: int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    $factor: int = 4;
        \\    print(apply(Fn, @func(v: int): int {
        \\        return v * factor;
        \\    }, 5));
        \\}
    ;
    try helpers.expectEmitContains(allocator, src, "lls_closure_fn_");
    try helpers.expectEmitOmits(allocator, src, ".call(ctx");
}

test "pipeline native execution: generic higher-order function with a closure" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@func apply(F: type, f: F, x: int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    $factor: int = 4;
        \\    print(apply(Fn, @func(v: int): int {
        \\        return v * factor;
        \\    }, 5));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "20\n");
}

test "pipeline native execution: generic function returning its closure parameter" {
    const allocator = std.testing.allocator;
    // The parameter outlives the instance's frame, so this must keep the heap
    // environment the stack-allocation path would have handed back.
    const src =
        \\@type Fn = @func(int): int;
        \\@func keep(F: type, f: F): F {
        \\    return f;
        \\}
        \\pub @func main() {
        \\    $factor: int = 2;
        \\    $doubled = keep(Fn, @func(v: int): int {
        \\        return v * factor;
        \\    });
        \\    print(doubled(21));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "42\n");
}

test "emitter: closure passed through a variable is called directly" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@func apply(F: type, f: F, x: int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    $factor: int = 4;
        \\    $scale = @func(v: int): int {
        \\        return v * factor;
        \\    };
        \\    print(apply(Fn, scale, 5));
        \\}
    ;
    try helpers.expectEmitContains(allocator, src, "lls_closure_fn_");
    try helpers.expectEmitOmits(allocator, src, ".call(ctx");
}

test "pipeline native execution: closure variable passed to a generic higher-order function" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@func apply(F: type, f: F, x: int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    $factor: int = 4;
        \\    $scale = @func(v: int): int {
        \\        return v * factor;
        \\    };
        \\    print(apply(Fn, scale, 5));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "20\n");
}

test "pipeline native execution: reassigned closure variable stays indirect" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@func apply(F: type, f: F, x: int): int {
        \\    return f(x);
        \\}
        \\pub @func main() {
        \\    $f = @func(v: int): int {
        \\        return v * 2;
        \\    };
        \\    print(apply(Fn, f, 5));
        \\    f = @func(v: int): int {
        \\        return v * 10;
        \\    };
        \\    print(apply(Fn, f, 5));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "10\n50\n");
}

test "emitter: generic method calls its bound closure trampoline directly" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@struct Runner {
        \\    tag: int;
        \\
        \\    @func apply(self, F: type, f: F, x: int): int {
        \\        return f(x);
        \\    }
        \\}
        \\pub @func main() {
        \\    $r: Runner = { tag: 0 };
        \\    $factor: int = 4;
        \\    print(r.apply(Fn, @func(v: int): int {
        \\        return v * factor;
        \\    }, 5));
        \\}
    ;
    try helpers.expectEmitContains(allocator, src, "lls_closure_fn_");
    try helpers.expectEmitOmits(allocator, src, ".call(ctx");
}

test "pipeline native execution: generic method higher-order function with a closure" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Fn = @func(int): int;
        \\@struct Runner {
        \\    tag: int;
        \\
        \\    @func apply(self, F: type, f: F, x: int): int {
        \\        return f(x);
        \\    }
        \\}
        \\pub @func main() {
        \\    $r: Runner = { tag: 0 };
        \\    $factor: int = 4;
        \\    print(r.apply(Fn, @func(v: int): int {
        \\        return v * factor;
        \\    }, 5));
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "20\n");
}

test "pipeline native execution: immediate closure IIFE" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $res = (@func(x: int): int {
        \\        return x * 3;
        \\    })(14);
        \\    print(res);
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "42\n");
}

test "emitter: closure held in a struct field is called directly" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Counter = {
        \\    increment: @func(): int;
        \\};
        \\pub @func main() {
        \\    $count: int = 0;
        \\    $a: Counter = Counter {
        \\        increment: @func(): int {
        \\            count = count + 1;
        \\            return count;
        \\        },
        \\    };
        \\    print(a.increment());
        \\}
    ;
    try helpers.expectEmitOmits(allocator, src, ".call(ctx");
}

test "pipeline native execution: struct fields through two locals keep their own closures" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Counter = {
        \\    next: @func(): int;
        \\};
        \\pub @func main() {
        \\    $n: int = 0;
        \\    $a: Counter = Counter {
        \\        next: @func(): int {
        \\            n = n + 1;
        \\            return n;
        \\        },
        \\    };
        \\    print(a.next());
        \\    print(a.next());
        \\    $m: int = 10;
        \\    $b: Counter = Counter {
        \\        next: @func(): int {
        \\            m = m + 5;
        \\            return m;
        \\        },
        \\    };
        \\    print(b.next());
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "1\n2\n15\n");
}

test "emitter: field of an address-taken struct stays indirect" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Counter = {
        \\    next: @func(): int;
        \\};
        \\@func bump(c: *Counter): int {
        \\    return c.next();
        \\}
        \\pub @func main() {
        \\    $n: int = 0;
        \\    $a: Counter = Counter {
        \\        next: @func(): int {
        \\            n = n + 1;
        \\            return n;
        \\        },
        \\    };
        \\    print(a.next());
        \\    print(bump(&a));
        \\}
    ;
    // `&a` lets `bump` overwrite the field, so neither call may assume a target.
    try helpers.expectEmitContains(allocator, src, ".call(ctx");
    try helpers.expectNativeStdout(allocator, src, "1\n2\n");
}

test "emitter: closure held in an array element is called directly" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $n: int = 0;
        \\    $handlers: [2]@func(): int = [
        \\        @func(): int {
        \\            n = n + 1;
        \\            return n;
        \\        },
        \\        @func(): int {
        \\            return 9;
        \\        },
        \\    ];
        \\    print(handlers[0]());
        \\    print(handlers[1]());
        \\}
    ;
    try helpers.expectEmitOmits(allocator, src, ".call(ctx");
}

test "pipeline native execution: array element closures keep their own environments" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $n: int = 0;
        \\    $handlers: [2]@func(): int = [
        \\        @func(): int {
        \\            n = n + 1;
        \\            return n;
        \\        },
        \\        @func(): int {
        \\            return 9;
        \\        },
        \\    ];
        \\    print(handlers[0]());
        \\    print(handlers[1]());
        \\    print(handlers[0]());
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "1\n9\n2\n");
}

test "emitter: array element stays indirect after an element write or a dynamic index" {
    const allocator = std.testing.allocator;
    const mutated =
        \\pub @func main() {
        \\    $n: int = 0;
        \\    $handlers: [2]@func(): int = [
        \\        @func(): int {
        \\            n = n + 1;
        \\            return n;
        \\        },
        \\        @func(): int {
        \\            return 8;
        \\        },
        \\    ];
        \\    print(handlers[0]());
        \\    handlers[0] = @func(): int {
        \\        n = n + 10;
        \\        return n;
        \\    };
        \\    print(handlers[0]());
        \\}
    ;
    // The write replaces the element, so the calls may not assume a target.
    try helpers.expectEmitContains(allocator, mutated, ".call(ctx");
    try helpers.expectNativeStdout(allocator, mutated, "1\n11\n");

    const dynamic =
        \\@func pick(xs: [2]@func(): int, i: int): int {
        \\    return xs[i]();
        \\}
        \\pub @func main() {
        \\    $handlers: [2]@func(): int = [
        \\        @func(): int {
        \\            return 7;
        \\        },
        \\        @func(): int {
        \\            return 8;
        \\        },
        \\    ];
        \\    print(handlers[0]());
        \\    print(pick(handlers, 1));
        \\}
    ;
    try helpers.expectEmitContains(allocator, dynamic, ".call(ctx");
    try helpers.expectNativeStdout(allocator, dynamic, "7\n8\n");
}

test "pipeline native execution: anonymous shape passed to a named type" {
    const allocator = std.testing.allocator;
    const src =
        \\@type P = { x: i64; y: i64; };
        \\@func take(p: P) { print(p.x); }
        \\pub @func main() {
        \\    $s: { x: i64; y: i64; } = { x: 1, y: 2 };
        \\    take(s);
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "1\n");
}

test "pipeline native execution: named type and shape alias convert both ways" {
    const allocator = std.testing.allocator;
    const src =
        \\@alias A = { x: i64; };
        \\@type B = { x: i64; };
        \\pub @func main() {
        \\    $a: A = { x: 1 };
        \\    $b: B = a;
        \\    $c: A = b;
        \\    print(b.x, c.x);
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "1 1\n");
}

test "pipeline native execution: concurrent native builds do not share a staged unit" {
    const allocator = std.testing.allocator;
    const count = 8;
    var paths: [count][]u8 = undefined;
    var children: [count]std.process.Child = undefined;
    var spawned: usize = 0;
    defer for (children[0..spawned]) |*child| {
        _ = child.wait() catch {};
    };
    defer for (paths[0..spawned]) |path| {
        std.fs.deleteFileAbsolute(path) catch {};
        allocator.free(path);
    };

    // Write every source first, then start the builds back to back: each build
    // stages its emitted Zig in the working directory, so overlapping builds are
    // what makes a shared staged name observable.
    for (0..count) |i| {
        const path = try std.fmt.allocPrint(allocator, "/tmp/llts_parallel_{d}_{x}.lls", .{ i, std.crypto.random.int(u32) });
        paths[i] = path;
        const source = try std.fmt.allocPrint(allocator, "pub @func main() {{\n    print({d});\n}}\n", .{i + 1});
        defer allocator.free(source);
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll(source);
    }
    for (0..count) |i| {
        children[i] = std.process.Child.init(&.{ "zig-out/bin/llts", "run", "--native", paths[i] }, allocator);
        children[i].stdout_behavior = .Pipe;
        children[i].stderr_behavior = .Pipe;
        try children[i].spawn();
        spawned += 1;
    }

    for (0..count) |i| {
        const stdout = try children[i].stdout.?.readToEndAlloc(allocator, 4096);
        defer allocator.free(stdout);
        const stderr = try children[i].stderr.?.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(stderr);
        const term = try children[i].wait();
        const code: u8 = switch (term) {
            .Exited => |c| @intCast(c),
            else => 1,
        };
        if (code != 0) {
            std.debug.print("Concurrent native run {d} failed with code {d}:\n{s}\n", .{ i, code, stderr });
            return error.ConcurrentNativeRunFailed;
        }
        var expected_buf: [8]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "{d}\n", .{i + 1});
        try std.testing.expectEqualStrings(expected, stdout);
    }
}

test "pipeline native execution: closure called through a struct field" {
    const allocator = std.testing.allocator;
    const src =
        \\@type Counter = {
        \\    increment: @func(): int;
        \\    value: @func(): int;
        \\};
        \\@func makeCounter(): Counter {
        \\    $count: int = 0;
        \\    return Counter {
        \\        increment: @func(): int {
        \\            count = count + 1;
        \\            return count;
        \\        },
        \\        value: @func(): int {
        \\            return count;
        \\        },
        \\    };
        \\}
        \\pub @func main() {
        \\    $a = makeCounter();
        \\    print(a.increment());
        \\    print(a.increment());
        \\    print(a.value());
        \\    $b = makeCounter();
        \\    print(b.value());
        \\}
    ;
    try helpers.expectNativeStdout(allocator, src, "1\n2\n2\n0\n");
}
