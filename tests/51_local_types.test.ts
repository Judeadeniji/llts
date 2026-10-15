import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("local types: @alias and @type inside a function body", () => {
	expectOutput(
		runSource(`
@func f(x: i64): i64 {
    @alias N = i64;
    $y: N = x;
    return y;
}
pub @func main() {
    @type M = i64;
    $m: M = @as(M, 3);
    print(@typeOf(m));
    print(f(2));
}
`),
		["M", "2"],
	);
});

test("local types: same name in different functions stays distinct", () => {
	expectOutput(
		runSource(`
@func a() {
    @type T = i64;
    $t = T(5);
    print(@typeOf(t));
    print(@sizeOf(T));
}
@func b() {
    @type T = u8;
    $t: T = @as(T, 7);
    print(@typeOf(t));
    print(@sizeOf(T));
    print(@typeOf(t) == T);
}
pub @func main() {
    a();
    b();
}
`),
		["T", "8", "T", "1", "true"],
	);
});

test("local types: shapes, nested blocks, and methods", () => {
	expectOutput(
		runSource(`
@struct Box {
    n: i64;
    @func kind(self: Box) {
        @alias K = i64;
        $k: K = self.n;
        print(@typeOf(k));
    }
}
pub @func main() {
    @type Pair = { x: i64; y: i64; };
    $p = Pair { x: 1, y: 2 };
    print(p.x + p.y);
    print(@typeOf(p));
    @if (true) {
        @alias Inner = ?i64;
        $o: Inner = null;
        print(@typeOf(o));
    }
    $bx = Box { n: 4 };
    bx.kind();
}
`),
		["3", "Pair", "?i64", "i64"],
	);
});

test("local types: not visible outside the declaring function", () => {
	expectError(
		runSource(`
@func f() { @type T = i64; }
@func g() { $x: T = 1; }
pub @func main() { f(); g(); }
`),
		"Unknown type 'T'",
	);
});

test("local types: duplicate name in one function is rejected", () => {
	expectError(
		runSource(`
@func f() {
    @type T = i64;
    @type T = u8;
}
pub @func main() { f(); }
`),
		"Duplicate type 'T' in function 'f'",
	);
});

test("local types: a variable cannot share a local type's name", () => {
	expectError(
		runSource(`
@func f() {
    @type T = i64;
    $T = 1;
}
pub @func main() { f(); }
`),
		"'T' is declared as both a type and a variable",
	);
});

test("local types: block-scoped, shadowing outer and global types", () => {
	expectOutput(
		runSource(`
@alias T = i64;
pub @func main() {
    @alias U = u8;
    @if (true) {
        @alias T = u16;
        $a: T = 1;
        $u: U = 3;
        print(@typeOf(a));
        print(@typeOf(u));
        {
            @alias T = u32;
            $c: T = 4;
            print(@typeOf(c));
        }
        $d: T = 5;
        print(@typeOf(d));
    }
    $b: T = 2;
    print(@typeOf(b));
}
`),
		["u16", "u8", "u32", "u16", "i64"],
	);
});

test("local types: sibling blocks may reuse a name", () => {
	expectOutput(
		runSource(`
pub @func main() {
    @if (true) { @type T = i64; $x: T = @as(T, 1); print(@sizeOf(T)); }
    @if (true) { @type T = u8; $y: T = @as(T, 2); print(@sizeOf(T)); }
}
`),
		["8", "1"],
	);
});

test("local types: a block's type is not visible after the block", () => {
	expectError(
		runSource(`
pub @func main() {
    @if (true) { @alias T = i64; }
    $x: T = 1;
}
`),
		"Unknown type 'T'",
	);
});

test("local types: @comptime and labeled block expressions", () => {
	expectOutput(
		runSource(`
$g = @comptime {
    @alias G = i64;
    $v: G = 2;
    break v * 3;
};
print(g);
pub @func main() {
    $n = @comptime {
        @alias N = i64;
        $v: N = 6;
        break v * 7;
    };
    print(n);
    $e = blk: { @alias Q = u8; $q: Q = 9; break :blk q; };
    print(e);
}
`),
		["6", "42", "9"],
	);
});

test("local types: top-level blocks scope their types", () => {
	expectOutput(
		runSource(`
@if (true) {
    @alias H = u16;
    $h: H = 1;
    print(@typeOf(h));
}
@if (true) {
    @alias H = u8;
    $k: H = 1;
    print(@typeOf(k));
}
pub @func main() { }
`),
		["u16", "u8"],
	);
});

test("local types: a variable visible in an enclosing block cannot share the name", () => {
	expectError(
		runSource(`
pub @func main() {
    $x = 1;
    @if (true) { @alias x = i64; }
}
`),
		"'x' is declared as both a type and a variable",
	);
});
