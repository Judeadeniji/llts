import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("errdefer runs on error exit; defer always", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
$state = list.create();

@func f(fail) {
    defer list.push(state, 1);
    errdefer list.push(state, 10);
    @if (fail) {
        return error("Failed");
    }
    return true;
}

@func main() {
    f(false);
    print(list.len(state));
    print(list.get(state, 0));

    $err = f(true);
    print(@isError(err));
    print(list.len(state));
    print(list.get(state, 1));
    print(list.get(state, 2));
}
main();
`),
		["1", "1", "true", "3", "10", "1"],
	);
});

test("errdefer LIFO with defer on success path", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");

@func okFn(l) {
    defer list.push(l, 1);
    errdefer list.push(l, 2);
    defer list.push(l, 3);
    errdefer list.push(l, 4);
    return true;
}

@func main() {
    $l = list.create();
    okFn(l);
    print(list.len(l));
    print(list.get(l, 0));
    print(list.get(l, 1));
}
main();
`),
		["2", "3", "1"],
	);
});

test("errdefer LIFO with defer on error path", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");

@func failFn(l) {
    defer list.push(l, 1);
    errdefer list.push(l, 2);
    defer list.push(l, 3);
    errdefer list.push(l, 4);
    return error("Oops");
}

@func main() {
    $l = list.create();
    $err = failFn(l);
    print(@isError(err));
    print(list.len(l));
    print(list.get(l, 0));
    print(list.get(l, 1));
    print(list.get(l, 2));
    print(list.get(l, 3));
}
main();
`),
		["true", "4", "4", "3", "2", "1"],
	);
});

test("errdefer with try operator unwinding", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
$state = list.create();

@func throws() {
    return error("Crash");
}

@func catches() {
    defer list.push(state, 1);
    errdefer list.push(state, 2);
    throws() ?;
    return true;
}

@func main() {
    $err = catches();
    print(@isError(err));
    print(list.get(state, 0));
    print(list.get(state, 1));
}
main();
`),
		["true", "2", "1"],
	);
});

test("errdefer does not run on break", () => {
	expectOutput(
		runSource(`
@func main() {
    $x = 0;
    @for (true) {
        defer x = x + 1;
        errdefer x = x + 100;
        break;
    }
    print(x);
}
main();
`),
		["1"],
	);
});

test("errdefer does not run on continue", () => {
	expectOutput(
		runSource(`
@func main() {
    $x = 0;
    @for (0..3) |i| {
        defer x = x + 1;
        errdefer x = x + 100;
        continue;
    }
    print(x);
}
main();
`),
		["3"],
	);
});

test("nested block errdefer runs on ? unwind", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
$state = list.create();

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

@func main() {
    $err = outer();
    print(@isError(err));
    print(list.len(state));
    # Inner scope LIFO first (defer 2, then errdefer 20), then outer defer 1
    print(list.get(state, 0));
    print(list.get(state, 1));
    print(list.get(state, 2));
}
main();
`),
		["true", "3", "2", "20", "1"],
	);
});

test("return non-error after local error does not run errdefer", () => {
	expectOutput(
		runSource(`
@const $list = @import("std/list");
$state = list.create();

@func f() {
    defer list.push(state, 1);
    errdefer list.push(state, 10);
    $ignored = error("not returned");
    return 0;
}

@func main() {
    print(f());
    print(list.len(state));
    print(list.get(state, 0));
}
main();
`),
		["0", "1", "1"],
	);
});

test("error payloads: code, message, null and value", () => {
	expectOutput(
		runSource(`
$e1 = error("CodeOnly");
$e2 = error("WithPayload", 42);
print(e1.code);
print(e1.message);
print(e1.payload);
print(e2.code);
print(e2.payload);
`),
		["CodeOnly", "CodeOnly", "null", "WithPayload", "42"],
	);
});

test("error payload can be a map", () => {
	expectOutput(
		runSource(`
@const $map = @import("std/map");
$m = map.create();
map.set(m, "path", "/tmp/x");
$e = error("FileNotFound", m);
print(e.code);
print(map.get(e.payload, "path"));
`),
		["FileNotFound", "/tmp/x"],
	);
});
