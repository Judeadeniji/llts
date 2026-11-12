import { test } from "bun:test";
import { runSource, runSourceWithFixtures, expectOutput } from "./helpers";

test("errdefer runs on error exit; defer always", () => {
  expectOutput(
    runSourceWithFixtures(`
@const $list = @import("./list.lls");
$state = list.create(0);

@func f(fail) {
    defer list.push(state, 1);
    errdefer list.push(state, 10);
    @if (fail) {
        return error("Failed");
    }
    return true;
}

pub @func main() {
    f(false);
    print(list.len(state));
    print(list.get(state, 0));

    $err = f(true);
    print(@isError(err));
    print(list.len(state));
    print(list.get(state, 1));
    print(list.get(state, 2));
}
`),
    ["1", "1", "true", "3", "10", "1"],
  );
});

test("errdefer LIFO with defer on success path", () => {
  expectOutput(
    runSourceWithFixtures(`
@const $list = @import("./list.lls");

@func okFn(l) {
    defer list.push(l, 1);
    errdefer list.push(l, 2);
    defer list.push(l, 3);
    errdefer list.push(l, 4);
    return true;
}

pub @func main() {
    $l = list.create(0);
    okFn(l);
    print(list.len(l));
    print(list.get(l, 0));
    print(list.get(l, 1));
}
`),
    ["2", "3", "1"],
  );
});

test("errdefer LIFO with defer on error path", () => {
  expectOutput(
    runSourceWithFixtures(`
@const $list = @import("./list.lls");

@func failFn(l) {
    defer list.push(l, 1);
    errdefer list.push(l, 2);
    defer list.push(l, 3);
    errdefer list.push(l, 4);
    return error("Oops");
}

pub @func main() {
    $l = list.create(0);
    $err = failFn(l);
    print(@isError(err));
    print(list.len(l));
    print(list.get(l, 0));
    print(list.get(l, 1));
    print(list.get(l, 2));
    print(list.get(l, 3));
}
`),
    ["true", "4", "4", "3", "2", "1"],
  );
});

test("errdefer with try operator unwinding", () => {
  expectOutput(
    runSourceWithFixtures(`
@const $list = @import("./list.lls");
$state = list.create(0);

@func throws() {
    return error("Crash");
}

@func catches() {
    defer list.push(state, 1);
    errdefer list.push(state, 2);
    throws() ?;
    return true;
}

pub @func main() {
    $err = catches();
    print(@isError(err));
    print(list.get(state, 0));
    print(list.get(state, 1));
}
`),
    ["true", "2", "1"],
  );
});

test("errdefer does not run on break", () => {
  expectOutput(
    runSource(`
pub @func main() {
    $x = 0;
    @for (true) {
        defer x = x + 1;
        errdefer x = x + 100;
        break;
    }
    print(x);
}
`),
    ["1"],
  );
});

test("errdefer does not run on continue", () => {
  expectOutput(
    runSource(`
pub @func main() {
    $x = 0;
    @for (0..3) |i| {
        defer x = x + 1;
        errdefer x = x + 100;
        continue;
    }
    print(x);
}
`),
    ["3"],
  );
});

test("nested block errdefer runs on ? unwind", () => {
  expectOutput(
    runSourceWithFixtures(`
@const $list = @import("./list.lls");
$state = list.create(0);

@func throws() {
    return error("inner");
}

@func outer() {
    defer list.push(state, 1);
    @if (true) {
        errdefer list.push(state, 20);
        defer list.push(state, 2);
        throws() ?;
    }
    return true;
}

pub @func main() {
    $err = outer();
    print(@isError(err));
    print(list.len(state));
    # Inner scope LIFO first (defer 2, then errdefer 20), then outer defer 1
    print(list.get(state, 0));
    print(list.get(state, 1));
    print(list.get(state, 2));
}
`),
    ["true", "3", "2", "20", "1"],
  );
});

test("return non-error after local error does not run errdefer", () => {
  expectOutput(
    runSourceWithFixtures(`
@const $list = @import("./list.lls");
$state = list.create(0);

@func f() {
    defer list.push(state, 1);
    errdefer list.push(state, 10);
    $ignored = error("not returned");
    return 0;
}

pub @func main() {
    print(f());
    print(list.len(state));
    print(list.get(state, 0));
}
`),
    ["0", "1", "1"],
  );
});

test("errors carry a code and message", () => {
  expectOutput(
    runSource(`
$e = error("CodeOnly");
print(e.message);
print(e.message);
print(@nameOf(e));
`),
    ["CodeOnly", "CodeOnly", "CodeOnly"],
  );
});
