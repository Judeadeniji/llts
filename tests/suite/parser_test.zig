const std = @import("std");
const helpers = @import("helpers.zig");
const ast = helpers.ast;

test "parser: variable and constant declarations" {
    const allocator = std.testing.allocator;
    const src =
        \\$x = 42;
        \\$y: int = 10;
        \\@const $MAX = 100;
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 4), doc.statements.len);
    try std.testing.expect(doc.statements[0].* == .declaration);
    try std.testing.expectEqualStrings("x", doc.statements[0].declaration.name);

    try std.testing.expect(doc.statements[1].* == .declaration);
    try std.testing.expectEqualStrings("y", doc.statements[1].declaration.name);
    try std.testing.expect(doc.statements[1].declaration.type_annotation != null);

    try std.testing.expect(doc.statements[2].* == .declaration);
    try std.testing.expectEqualStrings("MAX", doc.statements[2].declaration.name);
    try std.testing.expect(doc.statements[2].declaration.is_const);

    try std.testing.expect(doc.statements[3].* == .function_decl);
    try std.testing.expectEqualStrings("main", doc.statements[3].function_decl.name);
    try std.testing.expect(doc.statements[3].function_decl.is_public);
}

test "parser: struct declaration with fields and methods" {
    const allocator = std.testing.allocator;
    const src =
        \\@struct Vector2 {
        \\    x: int;
        \\    y: int;
        \\    @func lengthSquared(self: *Vector2): int {
        \\        return self.x * self.x + self.y * self.y;
        \\    }
        \\}
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expect(doc.statements.len >= 2);
    try std.testing.expect(doc.statements[0].* == .struct_decl);
    const s = &doc.statements[0].struct_decl;
    try std.testing.expectEqualStrings("Vector2", s.name);
    try std.testing.expectEqual(@as(usize, 2), s.fields.len);
    try std.testing.expectEqualStrings("x", s.fields[0].name);
    try std.testing.expectEqualStrings("y", s.fields[1].name);
    try std.testing.expectEqual(@as(usize, 1), s.methods.len);
    try std.testing.expectEqualStrings("lengthSquared", s.methods[0].function_decl.name);
}

test "parser: enum and error declarations" {
    const allocator = std.testing.allocator;
    const src =
        \\@enum Status { Pending, Active, Done }
        \\@error FileError { NotFound, AccessDenied }
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expect(doc.statements.len >= 3);
    try std.testing.expect(doc.statements[0].* == .enum_decl);
    try std.testing.expectEqualStrings("Status", doc.statements[0].enum_decl.name);
    try std.testing.expectEqual(@as(usize, 3), doc.statements[0].enum_decl.variants.len);

    try std.testing.expect(doc.statements[1].* == .error_decl);
    try std.testing.expectEqualStrings("FileError", doc.statements[1].error_decl.name);
}

test "parser: control flow (@if, @switch, @for)" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    @if (true) {
        \\        print("yes");
        \\    } @else {
        \\        print("no");
        \\    }
        \\    @switch (1) {
        \\        1 => { print(1); },
        \\        @else => { print(0); },
        \\    }
        \\    @for (0..10) |i| {
        \\        print(i);
        \\    }
        \\}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.statements.len);
    const body = doc.statements[0].function_decl.body.block.statements;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[0].* == .if_expr);
    try std.testing.expect(body[1].* == .switch_expr);
    try std.testing.expect(body[2].* == .for_expr);
}

test "parser: anonymous @func expression and nested @func" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    $f = @func(x: int): int { return x + 1; };
        \\    @func inner(y: int): int { return y * 2; }
        \\}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.statements.len);
    const body = doc.statements[0].function_decl.body.block.statements;
    try std.testing.expectEqual(@as(usize, 2), body.len);

    // 1. $f = @func(x: int): int { ... }
    try std.testing.expect(body[0].* == .declaration);
    const decl_val = body[0].declaration.value;
    try std.testing.expect(decl_val.* == .function_decl);
    try std.testing.expectEqualStrings("", decl_val.function_decl.name);
    try std.testing.expect(decl_val.function_decl.return_type != null);

    // 2. @func inner(y: int): int { ... }
    try std.testing.expect(body[1].* == .function_decl);
    try std.testing.expectEqualStrings("inner", body[1].function_decl.name);
}

test "parser: syntax error produces failure" {
    const allocator = std.testing.allocator;
    const invalid_src = "pub @func main( {"; // unclosed paren
    const res = helpers.parseSource(allocator, invalid_src);
    try std.testing.expectError(error.ParseFailed, res);
}

fn expectParseDiagnostic(
    allocator: std.mem.Allocator,
    source: []const u8,
    needle: []const u8,
) !void {
    var parsed = try helpers.parseSourceDetailed(allocator, source);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.diagnostics.items.len > 0);
    for (parsed.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, needle) != null) return;
    }
    std.debug.print("Expected a diagnostic containing '{s}', got:\n", .{needle});
    for (parsed.diagnostics.items) |diag| {
        std.debug.print("  {d}:{d}: {s}\n", .{ diag.line, diag.column, diag.message });
    }
    return error.ExpectedDiagnosticMissing;
}

test "parser: extern functions carry full C signatures" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" @func puts(s: c_str): i32;
        \\@extern "c" @func getpid(): i32;
        \\@extern "c" @func strlen(s: c_str): usize;
        \\@extern "c" @func getenv(name: c_str): ?c_str;
        \\@extern "c" @func malloc(size: usize): ?*u8;
        \\@extern "c" @func free(ptr: ?*u8): void;
        \\@extern "c" @func write(fd: i32, buf: *u8, count: usize): isize;
        \\@extern "c" @func printf(fmt: c_str, ...): i32;
        \\pub @func main() {}
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 9), doc.statements.len);

    const puts_decl = &doc.statements[0].extern_decl;
    try std.testing.expectEqual(ast.ExternKind.func, puts_decl.kind);
    try std.testing.expectEqualStrings("puts", puts_decl.name);
    try std.testing.expectEqualStrings("puts", puts_decl.symbol);
    try std.testing.expectEqualStrings("c", puts_decl.abi);
    try std.testing.expect(puts_decl.is_public);
    try std.testing.expect(!puts_decl.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), puts_decl.params.len);
    try std.testing.expectEqualStrings("s", puts_decl.params[0].name);
    const s_type = puts_decl.params[0].type_annotation orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c_str", s_type.primary.name);
    const puts_ret = puts_decl.return_type orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("i32", puts_ret.primary.name);

    const getpid_decl = &doc.statements[1].extern_decl;
    try std.testing.expectEqual(@as(usize, 0), getpid_decl.params.len);
    try std.testing.expectEqualStrings("i32", getpid_decl.return_type.?.primary.name);

    const strlen_decl = &doc.statements[2].extern_decl;
    try std.testing.expectEqualStrings("c_str", strlen_decl.params[0].type_annotation.?.primary.name);
    try std.testing.expectEqualStrings("usize", strlen_decl.return_type.?.primary.name);

    const getenv_decl = &doc.statements[3].extern_decl;
    const getenv_ret = getenv_decl.return_type orelse return error.TestUnexpectedResult;
    try std.testing.expect(getenv_ret.* == .union_type);
    try std.testing.expectEqualStrings("c_str", getenv_ret.union_type.left.primary.name);
    try std.testing.expectEqualStrings("null", getenv_ret.union_type.right.primary.name);

    const malloc_decl = &doc.statements[4].extern_decl;
    try std.testing.expectEqualStrings("usize", malloc_decl.params[0].type_annotation.?.primary.name);
    const malloc_ret = malloc_decl.return_type orelse return error.TestUnexpectedResult;
    try std.testing.expect(malloc_ret.* == .union_type);
    try std.testing.expect(malloc_ret.union_type.left.* == .pointer_type);
    try std.testing.expectEqualStrings("u8", malloc_ret.union_type.left.pointer_type.elem.primary.name);

    const free_decl = &doc.statements[5].extern_decl;
    const free_param = free_decl.params[0].type_annotation orelse return error.TestUnexpectedResult;
    try std.testing.expect(free_param.* == .union_type);
    try std.testing.expect(free_param.union_type.left.* == .pointer_type);
    try std.testing.expectEqualStrings("void", free_decl.return_type.?.primary.name);

    const write_decl = &doc.statements[6].extern_decl;
    try std.testing.expectEqual(@as(usize, 3), write_decl.params.len);
    try std.testing.expectEqualStrings("fd", write_decl.params[0].name);
    try std.testing.expectEqualStrings("buf", write_decl.params[1].name);
    try std.testing.expectEqualStrings("count", write_decl.params[2].name);
    try std.testing.expectEqualStrings("isize", write_decl.return_type.?.primary.name);

    const printf_decl = &doc.statements[7].extern_decl;
    try std.testing.expect(printf_decl.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), printf_decl.params.len);
    try std.testing.expectEqualStrings("fmt", printf_decl.params[0].name);

    try std.testing.expect(doc.statements[8].* == .function_decl);
}

test "parser: extern function may omit its return type" {
    const allocator = std.testing.allocator;
    const src =
        \\@extern "c" @func noop();
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.statements.len);
    const noop_decl = &doc.statements[0].extern_decl;
    try std.testing.expectEqual(ast.ExternKind.func, noop_decl.kind);
    try std.testing.expect(noop_decl.return_type == null);
    try std.testing.expectEqual(@as(usize, 0), noop_decl.params.len);
}

test "parser: extern data form parses for tooling" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @extern "c" errno: i32;
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.statements.len);
    const errno_decl = &doc.statements[0].extern_decl;
    try std.testing.expectEqual(ast.ExternKind.data, errno_decl.kind);
    try std.testing.expectEqualStrings("errno", errno_decl.name);
    try std.testing.expectEqualStrings("errno", errno_decl.symbol);
    try std.testing.expectEqualStrings("c", errno_decl.abi);
    try std.testing.expect(errno_decl.is_public);
    try std.testing.expectEqual(@as(usize, 0), errno_decl.params.len);
    try std.testing.expect(errno_decl.return_type == null);
    try std.testing.expectEqualStrings("i32", errno_decl.data_type.?.primary.name);
}

test "parser: variadic extern keeps the fixed parameters" {
    const allocator = std.testing.allocator;
    const src =
        \\@extern "c" @func printf(fmt: c_str, ...): i32;
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    const printf_decl = &doc.statements[0].extern_decl;
    try std.testing.expect(printf_decl.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), printf_decl.params.len);
    try std.testing.expectEqualStrings("fmt", printf_decl.params[0].name);
}

test "parser: legacy extern form fails with a migration hint" {
    const allocator = std.testing.allocator;
    try expectParseDiagnostic(
        allocator,
        "pub @extern Allocator;\n",
        "legacy '@extern Name;' declarations are not supported",
    );
}

test "parser: nested extern declarations are rejected" {
    const allocator = std.testing.allocator;
    try expectParseDiagnostic(
        allocator,
        \\pub @func main() {
        \\    @extern "c" @func puts(s: c_str): i32;
        \\}
        \\
    ,
        "@extern declarations are only allowed at file scope",
    );
}

test "parser: extern varargs must be last" {
    const allocator = std.testing.allocator;
    try expectParseDiagnostic(
        allocator,
        \\@extern "c" @func bad(a: i32, ..., b: i32): i32;
        \\
    ,
        "no parameter may follow '...'",
    );
    try expectParseDiagnostic(
        allocator,
        \\@extern "c" @func bad(...): i32;
        \\
    ,
        "requires at least one fixed parameter",
    );
}

test "parser: extern parameters require an explicit type" {
    const allocator = std.testing.allocator;
    try expectParseDiagnostic(
        allocator,
        \\@extern "c" @func bad(a);
        \\
    ,
        "Expected ':' before extern parameter type",
    );
}

test "parser: extern functions cannot have a body" {
    const allocator = std.testing.allocator;
    try expectParseDiagnostic(
        allocator,
        \\@extern "c" @func bad(): i32 { return 1; }
        \\
    ,
        "extern function declarations cannot have a body",
    );
}

test "parser: extern requires an ABI string" {
    const allocator = std.testing.allocator;
    try expectParseDiagnostic(
        allocator,
        "@extern;\n",
        "Expected ABI string after @extern",
    );
}

test "parser: extern after a function body is still file scope" {
    const allocator = std.testing.allocator;
    const src =
        \\pub @func main() {
        \\    @if (true) { print("nested"); }
        \\}
        \\@extern "c" @func getpid(): i32;
    ;
    var doc = try helpers.parseSource(allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.statements.len);
    try std.testing.expect(doc.statements[0].* == .function_decl);
    try std.testing.expect(doc.statements[1].* == .extern_decl);
    try std.testing.expectEqualStrings("getpid", doc.statements[1].extern_decl.name);
}
