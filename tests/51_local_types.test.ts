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
