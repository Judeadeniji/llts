import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

test("all integer and float widths are distinct honest types", () => {
	expectOutput(
		runSource(`
$a: i8 = 1;
$b: i16 = 2;
$c: i32 = 3;
$d: i64 = 4;
$e: u8 = 5;
$f: u16 = 6;
$g: u32 = 7;
$h: u64 = 8;
$x: f32 = 1.5;
$y: f64 = 2.5;
print(@typeOf(a));
print(@typeOf(b));
print(@typeOf(c));
print(@typeOf(d));
print(@typeOf(e));
print(@typeOf(f));
print(@typeOf(g));
print(@typeOf(h));
print(@typeOf(x));
print(@typeOf(y));
print(a); print(b); print(c); print(d);
print(e); print(f); print(g); print(h);
print(x); print(y);
`),
		[
			"i8", "i16", "i32", "i64",
			"u8", "u16", "u32", "u64",
			"f32", "f64",
			"1", "2", "3", "4",
			"5", "6", "7", "8",
			"1.5", "2.5",
		],
	);
});

test("aliases int/byte/float/bool normalize to i64/u8/f64/u1", () => {
	expectOutput(
		runSource(`
$a: int = 1;
$b: byte = 2;
$c: float = 3.25;
$d: number = 4;
$e: bool = true;
$f: boolean = false;
print(@typeOf(a));
print(@typeOf(b));
print(@typeOf(c));
print(@typeOf(d));
print(@typeOf(e));
print(@typeOf(f));
`),
		["i64", "u8", "f64", "i64", "u1", "u1"],
	);
});

test("@sizeOf matches width sizes", () => {
	expectOutput(
		runSource(`
print(@sizeOf(i8));
print(@sizeOf(u8));
print(@sizeOf(u1));
print(@sizeOf(bool));
print(@sizeOf(i16));
print(@sizeOf(u16));
print(@sizeOf(i32));
print(@sizeOf(u32));
print(@sizeOf(f32));
print(@sizeOf(i64));
print(@sizeOf(u64));
print(@sizeOf(f64));
print(@sizeOf(int));
print(@sizeOf(byte));
print(@sizeOf(float));
`),
		["1", "1", "1", "1", "2", "2", "4", "4", "4", "8", "8", "8", "8", "1", "8"],
	);
});

test("@as converts between integer widths", () => {
	expectOutput(
		runSource(`
$n: i64 = 200;
$a = @as(u8, n);
$b = @as(i16, a);
$c = @as(i32, b);
$d = @as(u32, c);
$e = @as(u64, d);
$f = @as(i64, e);
print(@typeOf(a));
print(a);
print(f);
`),
		["u8", "200", "200"],
	);
});

test("mixed integer widths require @as", () => {
	expectError(
		runSource(`
$a: i32 = 1;
$b: i64 = 2;
print(a + b);
`),
		"mixed",
	);
});

test("packed struct fields use real width sizes", () => {
	expectOutput(
		runSource(`
@struct Packed {
    a: u8;
    b: u16;
    c: i32;
    d: f64;
}
print(@sizeOf(Packed));
$p = Packed { a: 1, b: 2, c: 3, d: 4.5 };
print(p.a);
print(p.b);
print(p.c);
print(p.d);
`),
		["16", "1", "2", "3", "4.5"],
	);
});
