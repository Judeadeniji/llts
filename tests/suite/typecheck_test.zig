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

test "ir: c_str display, equality, and assignability" {
    const allocator = std.testing.allocator;
    const ir = helpers.compiler.ir;

    const c_str = ir.namedType("c_str");
    try std.testing.expect(ir.typeEquals(c_str, ir.TCStr));
    try std.testing.expect(ir.isBuiltinTypeName("c_str"));
    try std.testing.expectEqualStrings("c_str", ir.displayType(c_str));
    try std.testing.expectEqualStrings("c_str", ir.displayTypeSimple(ir.TCStr).?);

    try std.testing.expect(ir.isSubtype(ir.TCStr, ir.TCStr));
    try std.testing.expect(ir.isSubtype(.{ .str_lit = "hello" }, ir.TCStr));
    try std.testing.expect(!ir.isSubtype(ir.TCStr, ir.TString));
    try std.testing.expect(!ir.isSubtype(ir.TString, ir.TCStr));
    try std.testing.expect(!ir.typeEquals(ir.TCStr, ir.TString));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };

    const optional = try ta.unionType(&.{ ir.TCStr, ir.TNull });
    const payload = ir.optionalPayload(optional) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ir.typeEquals(payload, ir.TCStr));
    try std.testing.expect(ir.isSubtype(ir.TCStr, optional));
    try std.testing.expect(ir.isSubtype(ir.TNull, optional));
    try std.testing.expect(ir.isSubtype(.{ .str_lit = "hello" }, optional));
    try std.testing.expect(!ir.isSubtype(optional, ir.TCStr));
    try std.testing.expect(!ir.isSubtype(ir.TString, optional));

    const disp = try ir.displayTypeAlloc(allocator, optional);
    defer allocator.free(disp);
    try std.testing.expectEqualStrings("?c_str", disp);

    const parsed = try ir.parseDisplayType(ta, "?c_str");
    try std.testing.expect(ir.typeEquals(parsed, optional));
}

test "ir: typeFromAst maps c_str and ?c_str" {
    const allocator = std.testing.allocator;
    const ir = helpers.compiler.ir;
    const from_ast = helpers.compiler.from_ast;

    const src =
        \\pub @extern "c" @func getenv(name: c_str): ?c_str;
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = ir.TypeAlloc{ .allocator = arena.allocator() };

    const extern_decl = &doc.statements[0].extern_decl;
    const param = try from_ast.typeFromAst(extern_decl.params[0].type_annotation, null, ta);
    try std.testing.expect(ir.typeEquals(param, ir.TCStr));

    const ret = try from_ast.typeFromAst(extern_decl.return_type, null, ta);
    const payload = ir.optionalPayload(ret) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ir.typeEquals(payload, ir.TCStr));
}

test "extern: registers native C signatures" {
    const allocator = std.testing.allocator;
    const ir = helpers.compiler.ir;
    const src =
        \\pub @extern "c" @func puts(s: c_str): i32;
        \\@extern "c" @func printf(fmt: c_str, ...): i32;
        \\@extern "c" @func malloc(size: usize): ?*u8;
        \\@extern "c" @func getenv(name: c_str): ?c_str;
        \\@extern "c" @func free(ptr: ?*u8): void;
        \\@extern "c" @func getpid(): i32;
        \\pub @func main() {}
    ;
    var analyzed = try helpers.analyzeSource(allocator, src, true);
    defer analyzed.deinit();

    const puts = analyzed.state.externs.get("puts").?;
    try std.testing.expectEqualStrings("puts", puts.symbol);
    try std.testing.expectEqualStrings("c", puts.abi);
    try std.testing.expectEqual(@as(usize, 1), puts.params.len);
    try std.testing.expectEqualStrings("s", puts.params[0].name);
    try std.testing.expect(puts.params[0].ctype == .c_str);
    try std.testing.expect(puts.ret == .scalar);
    try std.testing.expect(ir.typeEquals(puts.ret.scalar, ir.namedType("i32")));
    try std.testing.expect(!puts.is_c_variadic);

    const printf = analyzed.state.externs.get("printf").?;
    try std.testing.expect(printf.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), printf.params.len);

    const malloc = analyzed.state.externs.get("malloc").?;
    try std.testing.expect(malloc.ret == .optional_ptr);
    try std.testing.expect(ir.typeEquals(malloc.ret.optional_ptr.ptr.*, ir.namedType("u8")));

    const getenv = analyzed.state.externs.get("getenv").?;
    try std.testing.expect(getenv.ret == .optional_c_str);

    const free = analyzed.state.externs.get("free").?;
    try std.testing.expect(free.params[0].ctype == .optional_ptr);
    try std.testing.expect(free.ret == .scalar);
    try std.testing.expect(ir.typeEquals(free.ret.scalar, ir.TVoid));

    const getpid = analyzed.state.externs.get("getpid").?;
    try std.testing.expectEqual(@as(usize, 0), getpid.params.len);
}

test "extern: registration rejects invalid declarations" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\@extern "stdcall" @func f(): void;
        \\pub @func main() {}
        ,
        \\@extern "c" errno: i32;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: void): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: ?i32): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: ??c_str): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: string): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: []u8): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: [4]u8): void;
        \\pub @func main() {}
        ,
        \\@struct S { x: i32; }
        \\@extern "c" @func f(x: S): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: i32 | error): void;
        \\pub @func main() {}
        ,
        \\@struct S { x: i32; }
        \\@extern "c" @func f(x: ?*S): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: **u8): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(x: i32, x: i32): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(): void;
        \\@extern "c" @func f(): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(): void;
        \\@func f() {}
        \\pub @func main() {}
        ,
        \\@extern "c" @func f(): void;
        \\$f = 1;
        \\pub @func main() {}
        ,
        \\@extern "c" @func print(s: c_str): void;
        \\pub @func main() {}
        ,
        \\@extern "c" @func main(): i32;
        ,
    };
    for (cases, 0..) |src, i| {
        helpers.expectCompileFail(allocator, src) catch |err| {
            std.debug.print("extern rejection case {d} was accepted\n", .{i});
            return err;
        };
    }
}

test "extern: typechecks fixed calls, C returns, and variadic arguments" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" @func puts(s: c_str): i32;
        \\@extern "c" @func printf(fmt: c_str, ...): i32;
        \\@extern "c" @func malloc(size: usize): ?*u8;
        \\@extern "c" @func getenv(name: c_str): ?c_str;
        \\@extern "c" @func write(fd: i32, buf: *u8, n: usize): isize;
        \\pub @func main() {
        \\    $r: i32 = puts("hello");
        \\    $v: i32 = printf("%d\n", 42, true, "suffix", 1.5);
        \\    $p: ?*u8 = malloc(8);
        \\    $h: ?c_str = getenv("HOME");
        \\    $buf: [4]u8 = [1, 2, 3, 4];
        \\    $w: isize = write(1, "abc", 3);
        \\    $w2: isize = write(1, buf, 4);
        \\}
    ;
    var analyzed = try helpers.analyzeSource(allocator, src, true);
    defer analyzed.deinit();
    try std.testing.expectEqual(@as(usize, 6), analyzed.state.extern_calls.count());
}

test "extern: call typechecking rejects arity, types, and value uses" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\@extern "c" @func f(): void;
        \\pub @func main() { f(1); }
        ,
        \\@extern "c" @func f(x: i32): void;
        \\pub @func main() { f(); }
        ,
        \\@extern "c" @func f(x: i32): void;
        \\pub @func main() { f("x"); }
        ,
        \\@extern "c" @func f(s: c_str): void;
        \\pub @func main() { $s: string = "x"; f(s); }
        ,
        \\@extern "c" @func f(p: *u8): void;
        \\pub @func main() { f(null); }
        ,
        \\@extern "c" @func f(x: i32, ...): void;
        \\pub @func main() { $s: string = "x"; f(1, s); }
        ,
        \\@extern "c" @func f(x: i32, ...): void;
        \\pub @func main() { $o: ?i32 = null; f(1, o); }
        ,
        \\@extern "c" @func f(): i32;
        \\pub @func main() { $x: string = f(); }
        ,
        \\@extern "c" @func puts(s: c_str): i32;
        \\pub @func main() { print(puts); }
        ,
        \\@extern "c" @func puts(s: c_str): i32;
        \\pub @func main() { $t = @typeOf(puts); }
        ,
    };
    for (cases, 0..) |src, i| {
        helpers.expectCompileFail(allocator, src) catch |err| {
            std.debug.print("extern call rejection case {d} was accepted\n", .{i});
            return err;
        };
    }
}

test "extern: reachability treats extern calls as terminal" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" @func puts(s: c_str): i32;
        \\@extern "c" @func printf(fmt: c_str, ...): i32;
        \\pub @func main() {
        \\    $r: i32 = puts("hello");
        \\    $v: i32 = printf("%d\n", r);
        \\}
    ;
    var analyzed = try helpers.analyzeSource(allocator, src, false);
    defer analyzed.deinit();
    try std.testing.expectEqual(@as(usize, 2), analyzed.state.extern_calls.count());
}

test "extern: bytecode backend rejects extern declarations" {
    const allocator = std.testing.allocator;
    const compiler = helpers.compiler;
    const src =
        \\pub @extern "c" @func puts(s: c_str): i32;
        \\pub @func main() {
        \\    $r: i32 = puts("hello");
        \\}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();
    var state = try compiler.analyze(allocator, &doc, .{ .debug = true, .strict = true });
    defer {
        state.chunk.deinit();
        compiler.state_mod.deinit(&state);
    }
    try std.testing.expectError(error.CompileError, compiler.emitBytecode(&state, &doc));
}
