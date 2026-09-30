/**
 * Go-compatible fmt and modernized debug module tests.
 */
import { test } from "bun:test";
import { runSource, expectOutput } from "./helpers";

test("fmt.sprintf basic verbs: %v %d %s %t %x %b", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("val: %v, dec: %d, str: %s, bool: %t, hex: %x, bin: %b", 123, 456, "hello", true, 255, 10));
}
`),
		["val: 123, dec: 456, str: hello, bool: true, hex: ff, bin: 1010"],
	);
});

test("fmt.sprintf numeric bases and prefixes: %#x %#X %#b %o %O", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("%#x %#X %#b %o %O", 255, 255, 10, 64, 64));
}
`),
		["0xff 0XFF 0b1010 100 0o100"],
	);
});

test("fmt.sprintf padding, sign, and alignment: %+d %-10s %10s %05d", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("[%+d] [%+d] [%-8s] [%8s] [%06d]", 42, -42, "left", "right", 77));
}
`),
		["[+42] [-42] [left    ] [   right] [000077]"],
	);
});

test("fmt.sprintf precision on float and string: %.2f %.3s", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("%.2f %.4f %.3s", 3.14159, 2.5, "foobar"));
}
`),
		["3.14 2.5000 foo"],
	);
});

test("fmt.sprintf dynamic width and precision: %*s %.*f", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("[%*s] [%.*f]", 6, "cat", 3, 1.23456));
}
`),
		["[   cat] [1.235]"],
	);
});

test("fmt.sprintf argument indexing: %[2]s %[1]d", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("%[2]s is %[1]d years old", 25, "Alice"));
}
`),
		["Alice is 25 years old"],
	);
});

test("fmt.sprintf quoting: %q", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("%q %q", "hello world", 65));
}
`),
		["\"hello world\" 'A'"],
	);
});

test("fmt.sprintf type %T and syntax %#v", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("%T %T %T", 1, "s", true));
    print(fmt.sprintf("%#v", "text"));
}
`),
		["int string bool", "\"text\""],
	);
});

test("fmt.sprintf missing and extra argument diagnostics", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprintf("missing: %d %s", 1));
    print(fmt.sprintf("extra: %d", 1, 2, "three"));
}
`),
		[
			"missing: 1 %!s(MISSING)",
			"extra: 1%!(EXTRA int=2, string=three)",
		],
	);
});

test("fmt.sprint and fmt.sprintln rules", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    print(fmt.sprint("a", "b"));
    print(fmt.sprint(1, 2));
    print(fmt.sprint("x", 10));
    $ln = fmt.sprintln("hello", 42);
    print(ln);
}
`),
		["ab", "1 2", "x10", "hello 42"],
	);
});

test("fmt.errorf returns an Error value", () => {
	expectOutput(
		runSource(`
@const $fmt = @import("std/fmt");
pub @func main() {
    $err = fmt.errorf("failed with code %d: %s", 404, "not found");
    print(@isError(err));
}
`),
		["true"],
	);
});

test("debug.printLn and debug.print support Go fmt verbs", () => {
	expectOutput(
		runSource(`
@const $debug = @import("std/debug");
pub @func main() {
    debug.printLn("count: %d, name: %s", 5, "items");
    debug.print("hex: 0x%x", 171);
}
`),
		["count: 5, name: items", "hex: 0xab"],
	);
});

test("debug.printLn preserves legacy {s} {i} placeholders", () => {
	expectOutput(
		runSource(`
@const $debug = @import("std/debug");
pub @func main() {
    debug.printLn("legacy: {s} {i}", "test", 42);
}
`),
		["legacy: test 42"],
	);
});
