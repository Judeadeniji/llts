import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";
import fs from "fs";

// ---------------------------------------------------------------------------
// string module (existing, kept for regression)
// ---------------------------------------------------------------------------

test("string operations", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
@const $s = "Hello World";
print(string.len(s));
print(string.concat("Hello ", "World"));
print(string.substr(s, 0, 5));
print(string.indexOf(s, "World"));
$parts = string.split("a,b,c", ",");
print(parts[0]);
print(parts[1]);
print(parts[2]);
`),
    ["11", "Hello World", "Hello", "6", "a", "b", "c"],
  );
});

test("string operations: edge cases", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
print(string.len(""));
print(string.indexOf("Hello", "xyz"));
print(string.substr("Hello", 2, 0));
print(len(string.split("no-delim-here", ",")));
print(len(string.split("", ",")));
`),
    ["0", "-1", "", "1", "1"],
  );
});

test("string operations: case conversion and trim", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
print(string.toUpper("hello"));
print(string.toLower("HELLO"));
print(string.trim("   padded   "));
`),
    ["HELLO", "hello", "padded"],
  );
});

test("string operations: replace and repeat", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
print(string.replace("foo bar foo", "foo", "baz"));
print(string.repeat("ab", 3));
`),
    ["baz bar baz", "ababab"],
  );
});

test("string operations: startsWith and endsWith", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
print(string.startsWith("Hello World", "Hello"));
print(string.startsWith("Hello World", "World"));
print(string.endsWith("Hello World", "World"));
print(string.endsWith("Hello World", "Hello"));
`),
    ["true", "false", "true", "false"],
  );
});

test("string operations: substr with out-of-range length clamps to end", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
@const $s = "Hi";
print(string.substr(s, 0, 100));
`),
    ["Hi"],
  );
});

test("string operations: negative index to indexOf on empty haystack", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
print(string.indexOf("", "x"));
`),
    ["-1"],
  );
});

// ---------------------------------------------------------------------------
// math module (existing, kept for regression)
// ---------------------------------------------------------------------------

test("math operations", () => {
  expectOutput(
    runSource(`
@const $math = @import("std/math");
print(math.min(10, 5));
print(math.max(10, 5));
print(math.abs(-10));
print(math.floor(5.9));
print(math.ceil(5.1));
`),
    ["5", "10", "10", "5", "6"],
  );
});

test("math operations: additional functions", () => {
  expectOutput(
    runSource(`
@const $math = @import("std/math");
print(math.round(5.5));
print(math.round(5.4));
print(math.pow(2, 10));
print(math.sqrt(64));
`),
    ["6", "5", "1024", "8"],
  );
});

test("math operations: edge cases with zero and negatives", () => {
  expectOutput(
    runSource(`
@const $math = @import("std/math");
print(math.abs(0));
print(math.min(-5, -10));
print(math.max(-5, -10));
print(math.floor(-5.1));
print(math.ceil(-5.9));
`),
    ["0", "-10", "-5", "-6", "-5"],
  );
});

test("math operations: min/max with more than two arguments", () => {
  expectOutput(
    runSource(`
@const $math = @import("std/math");
print(math.min(3, 1, 4, 1, 5));
print(math.max(3, 1, 4, 1, 5));
`),
    ["1", "5"],
  );
});

test("math.sqrt of a negative number returns an error", () => {
  expectOutput(
    runSource(`
@const $math = @import("std/math");
$r = math.sqrt(-4);
print(@isError(r));
`),
    ["true"],
  );
});

test("math constants: pi and e", () => {
  expectOutput(
    runSource(`
@const $math = @import("std/math");
print(math.floor(math.PI * 100));
print(math.floor(math.E * 100));
`),
    ["314", "271"],
  );
});

// ---------------------------------------------------------------------------
// io module (existing, kept for regression)
// ---------------------------------------------------------------------------

test("io operations", () => {
  fs.writeFileSync("test.txt", "hello io");
  expectOutput(
    runSource(`
@const $io = @import("std/io");
print(io.readFile("test.txt"));
`),
    ["hello io"],
  );
  fs.unlinkSync("test.txt");
});

test("io.writeFile creates a file with the given content", () => {
  runSource(`
@const $io = @import("std/io");
io.writeFile("write_test.txt", "written by lls");
`);
  const content = fs.readFileSync("write_test.txt", "utf8");
  if (content !== "written by lls") {
    throw new Error(`Expected file content "written by lls", got "${content}"`);
  }
  fs.unlinkSync("write_test.txt");
});

test("io.exists returns true for an existing file and false otherwise", () => {
  fs.writeFileSync("exists_test.txt", "x");
  expectOutput(
    runSource(`
@const $io = @import("std/io");
print(io.exists("exists_test.txt"));
print(io.exists("definitely_missing_file.txt"));
`),
    ["true", "false"],
  );
  fs.unlinkSync("exists_test.txt");
});

test("io.readFile on a missing file returns an error rather than throwing", () => {
  expectOutput(
    runSource(`
@const $io = @import("std/io");
$r = io.readFile("does_not_exist_anywhere.txt");
print(@isError(r));
`),
    ["true"],
  );
});

test("io.deleteFile removes a file", () => {
  fs.writeFileSync("delete_test.txt", "bye");
  runSource(`
@const $io = @import("std/io");
io.deleteFile("delete_test.txt");
`);
  if (fs.existsSync("delete_test.txt")) {
    throw new Error("Expected delete_test.txt to be removed");
  }
});

test("io.appendFile appends rather than overwrites", () => {
  fs.writeFileSync("append_test.txt", "first-");
  runSource(`
@const $io = @import("std/io");
io.appendFile("append_test.txt", "second");
`);
  const content = fs.readFileSync("append_test.txt", "utf8");
  if (content !== "first-second") {
    throw new Error(`Expected "first-second", got "${content}"`);
  }
  fs.unlinkSync("append_test.txt");
});

// ---------------------------------------------------------------------------
// Module import mechanics
// ---------------------------------------------------------------------------

test("importing an unknown module name is a compile-time error", () => {
  expectError(runSource(`
@const $nope = @import("not_a_real_module");
`), "CompileError: Unknown module 'not_a_real_module'");
});

test("aliasing two different modules to distinct names works independently", () => {
  expectOutput(runSource(`
@const $s = @import("std/string");
@const $m = @import("std/math");
print(s.len("abcd"));
print(m.max(1, 9));
`), ["4", "9"]);
});

test("importing the same module twice under different aliases both work", () => {
  expectOutput(runSource(`
@const $m1 = @import("std/math");
@const $m2 = @import("std/math");
print(m1.abs(-3));
print(m2.abs(-3));
`), ["3", "3"]);
});

test("calling a module function that doesn't exist is a compile-time error", () => {
  expectError(runSource(`
@const $math = @import("std/math");
print(math.notARealFunction(1));
`), "CompileError: 'math' has no export 'notARealFunction'");
});

test("using a module namespace without importing it is a compile-time error", () => {
  expectError(runSource(`
print(string.len("hi"));
`), "CompileError: Unknown identifier 'string'");
});

// ---------------------------------------------------------------------------
// Cross-module composition
// ---------------------------------------------------------------------------

test("chaining string and math module calls together", () => {
  expectOutput(runSource(`
@const $string = @import("std/string");
@const $math = @import("std/math");
@const $s = "12345";
print(math.max(string.len(s), 3));
`), ["5"]);
});

test("io.writeFile followed by io.readFile round-trips content built from string module", () => {
  runSource(`
@const $io = @import("std/io");
@const $string = @import("std/string");
$msg = string.concat("round", "trip");
io.writeFile("roundtrip_test.txt", msg);
print(io.readFile("roundtrip_test.txt"));
`);
  const content = fs.readFileSync("roundtrip_test.txt", "utf8");
  if (content !== "roundtrip") {
    throw new Error(`Expected "roundtrip", got "${content}"`);
  }
  fs.unlinkSync("roundtrip_test.txt");
});