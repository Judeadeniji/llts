import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("@sizeOf works for primitive types statically", () => {
	expectOutput(runSource(`
print(@sizeOf(int));
print(@sizeOf(float));
print(@sizeOf(bool));
print(@sizeOf(null));
print(@sizeOf(string));
`), ["8", "8", "1", "0", "8"]);
});

test("@sizeOf works for structs statically", () => {
	expectOutput(runSource(`
@struct Point {
    x: int;
    y: int;
    z: int;
}
print(@sizeOf(Point));

$p = Point { x: 1, y: 2, z: 3 };
print(@sizeOf(p));
`), ["24", "24"]);
});

test("@sizeOf works for runtime dynamic variables", () => {
	expectOutput(runSource(`
$x = 100;
print(@sizeOf(x));

$b = true;
print(@sizeOf(b));

$s = "hello";
print(@sizeOf(s));

$arr = [1, 2, 3, 4];
print(@sizeOf(arr));
`), ["8", "1", "4", "4"]);
});
