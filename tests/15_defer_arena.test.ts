/**
 * defer (LIFO scope exit) + an arena-shaped allocator from the test fixtures.
 */
import { test } from "bun:test";
import { expectOutput, runSource, runSourceWithFixtures } from "./helpers";

test("defer runs on fallthrough in LIFO order", () => {
  expectOutput(
    runSource(`
pub @func main() {
    defer print(1);
    defer print(2);
    print(0);
}
`),
    ["0", "2", "1"],
  );
});

test("defer block runs multiple statements", () => {
  expectOutput(
    runSource(`
pub @func main() {
    defer {
        print(2);
        print(1);
    }
    print(0);
}
`),
    ["0", "2", "1"],
  );
});

test("defer runs on return", () => {
  expectOutput(
    runSource(`
@func work() {
    defer print("cleanup");
    return 7;
}

print(work());
`),
    ["cleanup", "7"],
  );
});

test("defer runs on break from for", () => {
  expectOutput(
    runSource(`
pub @func main() {
    @for (true) {
        defer print("left");
        break;
    }
    print("after");
}
`),
    ["left", "after"],
  );
});

test("defer runs on ? error return", () => {
  expectOutput(
    runSource(`
@func boom(): int | error {
    defer print("def");
    return error("x")?;
}

$r = boom();
print(@isError(r));
`),
    ["def", "true"],
  );
});

test("Arena create alloc reset deinit with defer", () => {
  expectOutput(
    runSourceWithFixtures(`
$mem = @import("./mem.lls");

pub @func main() {
    $arena = mem.create(32);
    defer arena.deinit();
    $a = arena.alloc(4);
    $b = arena.alloc(4);
    print(b - a);
    arena.reset();
    $c = arena.alloc(4);
    print(c - a);
}
`),
    ["4", "0"],
  );
});

test("Arena hands out distinct offsets past the initial hint", () => {
  expectOutput(
    runSourceWithFixtures(`
$mem = @import("./mem.lls");
pub @func main() {
    $arena = mem.create(2);
    defer arena.deinit();
    $a = arena.alloc(8);
    $b = arena.alloc(8);
    print(a > 0);
    print(b > 0);
}
`),
    ["true", "true"],
  );
});

test("Arena create(0) still allocates", () => {
  expectOutput(
    runSourceWithFixtures(`
$mem = @import("./mem.lls");
pub @func main() {
    $arena = mem.create(0);
    defer arena.deinit();
    $p = arena.alloc(100);
    print(p > 0);
}
`),
    ["true"],
  );
});

test("bump alloc still works", () => {
  expectOutput(
    runSourceWithFixtures(`
$mem = @import("./mem.lls");
$p = mem.alloc(3);
print(p > 0);
`),
    ["true"],
  );
});
