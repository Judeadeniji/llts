import { test } from "bun:test";
import { expectError, expectOutput, runSourceStrict } from "./helpers";

test("flow: null-check narrows optional struct in then-branch", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "zoe" };
    @if (u != null) {
        print(u.name);
    }
}
`),
		["zoe"],
	);
});

test("flow: null-check narrows call-return optional", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
@func make(): ?User {
    return (User { name: "ann" });
}
pub @func main() {
    $u = make();
    @if (u != null) {
        print(u.name);
    }
}
`),
		["ann"],
	);
});

test("flow: assignment narrows optional to struct", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = null;
    u = User { name: "set" };
    print(u.name);
}
`),
		["set"],
	);
});

test("flow: else-branch of null-check narrows to struct", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "e" };
    @if (u == null) {
        print("n");
    } @else {
        print(u.name);
    }
}
`),
		["e"],
	);
});

test("flow: truthiness @if capture narrows the variable itself", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "cap" };
    @if (u) |v| {
        print(u.name);
        print(v.name);
    }
}
`),
		["cap", "cap"],
	);
});

test("flow: assignment inside narrowed branch re-widens", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "x" };
    @if (u != null) {
        u = null;
    }
    print("re-widened");
}
`),
		["re-widened"],
	);
});

test("flow: field access after join is not narrowed", () => {
	expectError(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "j" };
    @if (u != null) {
        print("in");
    }
    print(u.name);
}
`),
		"cannot access field 'name' on optional type '?User'",
	);
});

test("flow: field access in null branch is not narrowed", () => {
	expectError(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "j" };
    @if (u == null) {
        print(u.name);
    }
}
`),
		"cannot access field 'name' on type 'null'",
	);
});

test("flow: optional stays optional without any narrowing", () => {
	expectError(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = User { name: "j" };
    print(u.name);
}
`),
		"cannot access field 'name' on optional type '?User'",
	);
});

test("flow: assignment in else joins with then-narrowing to struct", () => {
	expectOutput(
		runSourceStrict(`
@struct User { name: string; }
pub @func main() {
    $u: ?User = null;
    @if (u != null) {
        print(u.name);
    } @else {
        u = User { name: "late" };
    }
    print(u.name);
}
`),
		["late"],
	);
});
