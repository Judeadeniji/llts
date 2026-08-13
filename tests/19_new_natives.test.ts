import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// ---------------------------------------------------------------------------
// string — parseInt / parseFloat / fromCharCode / charCodeAt
// ---------------------------------------------------------------------------

test("string: parseInt decimal and hex", () => {
	expectOutput(
		runSource(`
@const $s = @import("std/string");
print(s.parseInt("123", 10));
print(s.parseInt("ff", 16));
print(s.parseInt("-7", 10));
print(s.parseInt("0", 10));
`),
		["123", "255", "-7", "0"],
	);
});

test("string: parseInt invalid input returns 0", () => {
	expectOutput(
		runSource(`
@const $s = @import("std/string");
print(s.parseInt("nope", 10));
print(s.parseInt("", 10));
`),
		["0", "0"],
	);
});

test("string: parseFloat valid and invalid (nan)", () => {
	expectOutput(
		runSource(`
@const $s = @import("std/string");
@const $math = @import("std/math");
print(s.parseFloat("3.14"));
print(s.parseFloat("-2.5"));
print(math.isnan(s.parseFloat("nope")));
`),
		["3.14", "-2.5", "true"],
	);
});

test("string: fromCharCode and charCodeAt round-trip", () => {
	expectOutput(
		runSource(`
@const $s = @import("std/string");
print(s.fromCharCode(65));
print(s.fromCharCode(48));
print(s.charCodeAt("A", 0));
print(s.charCodeAt(s.fromCharCode(122), 0));
`),
		["A", "0", "65", "122"],
	);
});

test("string: fromCharCode out of range is an error", () => {
	expectOutput(
		runSource(`
@const $s = @import("std/string");
print(@isError(s.fromCharCode(300)));
print(s.fromCharCode(300).code);
print(@isError(s.fromCharCode(-1)));
`),
		["true", "InvalidCharCode", "true"],
	);
});

test("math: trig, log, exp at known points", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.sin(0.0));
print(math.cos(0.0));
print(math.tan(0.0));
print(math.log(1.0));
print(math.exp(0.0));
`),
		["0", "1", "0", "0", "1"],
	);
});

test("math: random is in [0, 1]", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
$r = math.random();
print(r >= 0.0);
print(r <= 1.0);
`),
		["true", "true"],
	);
});

test("math: abs, floor, ceil, round, trunc, sign", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.abs(-5));
print(math.floor(3.7));
print(math.ceil(3.2));
print(math.round(2.5));
print(math.trunc(3.9));
print(math.sign(-3));
print(math.sign(0));
print(math.sign(9));
`),
		["5", "3", "4", "3", "3", "-1", "0", "1"],
	);
});

test("math: pow, sqr, sqrt; sqrt of negative is error", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.pow(2, 10));
print(math.sqr(4));
print(math.sqrt(9));
print(@isError(math.sqrt(-1)));
`),
		["1024", "16", "3", "true"],
	);
});

test("math: min and max over rest args", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.min(3, 1, 2));
print(math.max(3, 1, 2));
print(math.min(-1, -5, 0));
print(math.max(-1, -5, 0));
`),
		["1", "3", "-5", "0"],
	);
});

test("math: hypot, fmod, copysign", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.hypot(3.0, 4.0));
print(math.fmod(7.0, 3.0));
print(math.copysign(1.0, -2.0));
print(math.copysign(-1.0, 2.0));
`),
		["5", "1", "-1", "1"],
	);
});

test("math: classification helpers and FP constants", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.isfinite(1.0));
print(math.isnan(math.nanValue()));
print(math.isinf(math.infinity()));
print(math.isinf(math.hugeVal()));
print(math.isgreater(2.0, 1.0));
print(math.isless(1.0, 2.0));
print(math.islessequal(1.0, 1.0));
print(math.signbit(-1.0));
print(math.signbit(1.0));
print(math.FP_NAN);
print(math.FP_INFINITE);
print(math.FP_ZERO);
print(math.FP_SUBNORMAL);
print(math.FP_NORMAL);
print(math.math_errhandling);
`),
		[
			"true",
			"true",
			"true",
			"true",
			"true",
			"true",
			"true",
			"true",
			"false",
			"0",
			"1",
			"2",
			"3",
			"4",
			"3",
		],
	);
});

test("math: PI and E are positive and ordered", () => {
	expectOutput(
		runSource(`
@const $math = @import("std/math");
print(math.PI > 3.0);
print(math.PI < 4.0);
print(math.E > 2.0);
print(math.E < 3.0);
`),
		["true", "true", "true", "true"],
	);
});

// ---------------------------------------------------------------------------
// os — env, cwd, platform, exec
// ---------------------------------------------------------------------------

test("os: cwd and PATH env are non-empty", () => {
	expectOutput(
		runSource(`
@const $os = @import("std/os");
$cwd = os.cwd();
$path = os.getEnv("PATH");
print(cwd != "");
print(path != "");
`),
		["true", "true"],
	);
});

test("os: platform is a non-empty string", () => {
	expectOutput(
		runSource(`
@const $os = @import("std/os");
$p = os.platform();
print(p != "");
`),
		["true"],
	);
});

test("os: exec captures stdout; true has empty stdout", () => {
	expectOutput(
		runSource(`
@const $os = @import("std/os");
@const $s = @import("std/string");
# echo includes a trailing newline in the captured stdout
print(s.trim(os.exec("echo hello")));
print(os.exec("printf hi"));
print(len(os.exec("true")));
`),
		["hello", "hi", "0"],
	);
});
test("os: setEnv, getEnv, pid, and args", () => {
	expectOutput(
		runSource(`
@const $os = @import("std/os");
os.setEnv("LLTS_TEST_KEY", "hello-llts");
print(os.getEnv("LLTS_TEST_KEY"));
print(os.getEnv("LLTS_NO_SUCH_ENV_VAR_XYZ") == null);
print(os.pid() > 0);
$a = os.args();
print(len(a) >= 1);
print(a[0] != "");
`),
		["hello-llts", "true", "true", "true", "true"],
	);
});

test("os: chdir changes cwd and can change back", () => {
	expectOutput(
		runSource(`
@const $os = @import("std/os");
@const $fs = @import("std/fs");
$orig = os.cwd();
fs.mkdir("test_chdir_tmp");
os.chdir("test_chdir_tmp");
$here = os.cwd();
print(here != orig);
os.chdir(orig);
print(os.cwd() == orig);
os.exec("rmdir test_chdir_tmp");
`),
		["true", "true"],
	);
});

// ---------------------------------------------------------------------------
// time — Go-shaped Duration / Time API
// ---------------------------------------------------------------------------

test("time: Duration unit constants scale correctly", () => {
	expectOutput(
		runSource(`
@const $time = @import("std/time");
print(time.Nanoseconds(time.Microsecond));
print(time.Microseconds(time.Millisecond));
print(time.Milliseconds(time.Second));
print(time.Seconds(time.Minute));
print(time.Minutes(time.Hour));
print(time.Hours(time.Hour));
`),
		["1000", "1000", "1000", "60", "60", "1"],
	);
});

test("time: Unix constructors and Equal / Add / Sub", () => {
	expectOutput(
		runSource(`
@const $time = @import("std/time");
print(time.Equal(time.Unix(1, 0), time.Second));
print(time.Equal(time.UnixMilli(1000), time.Second));
print(time.Equal(time.UnixNano(5000.0), 5000.0));
print(time.Equal(time.Add(time.Unix(1, 0), time.Second), time.Unix(2, 0)));
print(time.Sub(time.Unix(2, 0), time.Unix(1, 0)) == time.Second);
print(time.Equal(3.0 * time.Second, time.Add(time.Second, time.Add(time.Second, time.Second))));
`),
		["true", "true", "true", "true", "true", "true"],
	);
});

test("time: Before / After / Equal / IsZero", () => {
	expectOutput(
		runSource(`
@const $time = @import("std/time");
$a = time.Unix(1, 0);
$b = time.Unix(2, 0);
print(time.Before(a, b));
print(time.After(b, a));
print(time.Before(a, a));
print(time.After(a, a));
print(time.Equal(a, a));
print(time.IsZero(0.0));
print(time.IsZero(a));
`),
		["true", "true", "false", "false", "true", "true", "false"],
	);
});

test("time: Now / Since / Until / Sleep", () => {
	expectOutput(
		runSource(`
@const $time = @import("std/time");
$start = time.Now();
time.Sleep(10 * time.Millisecond);
$elapsed = time.Since(start);
print(time.After(time.Now(), start));
print(time.Milliseconds(elapsed) >= 5.0);
print(time.Until(time.Add(time.Now(), time.Second)) > 0.0);
time.Sleep(0.0);
time.Sleep(-1.0);
print(1);
`),
		["true", "true", "true", "1"],
	);
});

// ---------------------------------------------------------------------------
// fs — write/read/append/exists/delete/mkdir/stat
// ---------------------------------------------------------------------------

test("fs: write, read, append, exists, deleteFile", () => {
	expectOutput(
		runSource(`
@const $fs = @import("std/fs");
fs.writeFile("test_llts_fs_tmp.txt", "abc");
print(fs.exists("test_llts_fs_tmp.txt"));
print(fs.readFile("test_llts_fs_tmp.txt"));
fs.appendFile("test_llts_fs_tmp.txt", "d");
print(fs.readFile("test_llts_fs_tmp.txt"));
fs.deleteFile("test_llts_fs_tmp.txt");
print(fs.exists("test_llts_fs_tmp.txt"));
`),
		["true", "abc", "abcd", "false"],
	);
});

test("fs: readFile missing path returns FileNotFound error", () => {
	expectOutput(
		runSource(`
@const $fs = @import("std/fs");
$missing = fs.readFile("test_llts_no_such_file_xyz");
print(@isError(missing));
print(missing.code);
print(missing.payload);
print(fs.exists("test_llts_no_such_file_xyz"));
`),
		["true", "FileNotFound", "test_llts_no_such_file_xyz", "false"],
	);
});

test("fs: mkdir and stat directory kind", () => {
	expectOutput(
		runSource(`
@const $fs = @import("std/fs");
@const $os = @import("std/os");
fs.mkdir("test_mkdir_dir2");
$arr = fs.stat("test_mkdir_dir2");
print(arr[0] >= 0.0);
print(arr[4]);
os.exec("rmdir test_mkdir_dir2");
`),
		["true", "2"],
	);
});

test("fs: writeFile then stat reports file kind", () => {
	expectOutput(
		runSource(`
@const $fs = @import("std/fs");
fs.writeFile("test_llts_stat_file.txt", "x");
$arr = fs.stat("test_llts_stat_file.txt");
print(arr[0] >= 1.0);
print(arr[4]);
fs.deleteFile("test_llts_stat_file.txt");
`),
		["true", "1"],
	);
});

test("fs: rename and copyFile", () => {
	expectOutput(
		runSource(`
@const $fs = @import("std/fs");
fs.writeFile("test_llts_ren_a.txt", "src");
fs.copyFile("test_llts_ren_a.txt", "test_llts_ren_b.txt");
print(fs.readFile("test_llts_ren_b.txt"));
fs.rename("test_llts_ren_b.txt", "test_llts_ren_c.txt");
print(fs.exists("test_llts_ren_b.txt"));
print(fs.readFile("test_llts_ren_c.txt"));
fs.deleteFile("test_llts_ren_a.txt");
fs.deleteFile("test_llts_ren_c.txt");
`),
		["src", "false", "src"],
	);
});
