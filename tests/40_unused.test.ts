import { expect, test } from "bun:test";
import { runSource, runSourceAsWritten } from "./helpers.ts";

test("warns on unused local variable but does not fail compilation", () => {
	const res = runSource(`
pub @func main() {
    $unused_var = 42;
    print("ok");
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout).toContain("ok");
	expect(res.stderr).toContain("Warning: unused variable 'unused_var'");
});

test("warns on unused function parameter", () => {
	const res = runSource(`
@func compute(used: int, unused_arg: int): int {
    return used + 1;
}

pub @func main() {
    print(compute(10, 20));
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout).toContain("11");
	expect(res.stderr).toContain("Warning: unused parameter 'unused_arg'");
	expect(res.stderr).not.toContain("unused parameter 'used'");
});

test("warns on unused private function, struct, enum, and type alias", () => {
	const res = runSource(`
@func unused_fn() {}
@struct UnusedStruct { a: int; }
@enum UnusedEnum { A, B }
@type UnusedType = int;

pub @func main() {
    print("alive");
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout).toContain("alive");
	expect(res.stderr).toContain("Warning: unused function 'unused_fn'");
	expect(res.stderr).toContain("Warning: unused struct 'UnusedStruct'");
	expect(res.stderr).toContain("Warning: unused enum 'UnusedEnum'");
	expect(res.stderr).toContain("Warning: unused type 'UnusedType'");
});

test("underscore-prefixed declarations suppress unused warnings", () => {
	const res = runSource(`
@func _private_helper(_unused_param: int) {
    $_unused_local = 123;
}

pub @func main() {
    $x = 1;
    print(x);
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout).toContain("1");
	expect(res.stderr).not.toContain("Warning: unused");
});

test("pub declarations and entrypoint main are not warned as unused", () => {
	const res = runSource(`
pub @const $EXPORTED = 100;
pub @func exported_func() {}
pub @struct ExportedStruct { x: int; }

pub @func main() {
    print("done");
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout).toContain("done");
	expect(res.stderr).not.toContain("Warning: unused");
});

test("transitively referenced private declarations are not warned as unused", () => {
	const res = runSource(`
@struct Point {
    x: int;
    y: int;
}

@func helper(p: Point): int {
    return p.x + p.y;
}

pub @func main() {
    $p: Point = { x: 3, y: 4 };
    print(helper(p));
}
`);
	expect(res.exitCode).toBe(0);
	expect(res.stdout).toContain("7");
	expect(res.stderr).not.toContain("Warning: unused");
});
