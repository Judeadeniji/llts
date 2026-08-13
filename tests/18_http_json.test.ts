import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

// ---------------------------------------------------------------------------
// json.parse — types, nesting, errors
// ---------------------------------------------------------------------------

test("json.parse: object fields", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$val = json.parse("{\\"name\\": \\"Alice\\", \\"age\\": 30}");
print(val.name);
print(val.age);
`),
		["Alice", "30"],
	);
});

test("json.parse: nested object and bool", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$o = json.parse("{\\"user\\":{\\"id\\":1},\\"ok\\":true}");
print(o.user.id);
print(o.ok);
`),
		["1", "true"],
	);
});

test("json.parse: array of numbers", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$a = json.parse("[10, 20, 30]");
print(len(a));
print(a[0]);
print(a[2]);
`),
		["3", "10", "30"],
	);
});

test("json.parse: mixed array preserves null and bool", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$a = json.parse("[1, true, null]");
print(a[0]);
print(a[1]);
print(a[2]);
`),
		["1", "true", "null"],
	);
});

test("json.parse: primitives null, bool, float, string", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
print(json.parse("null"));
print(json.parse("false"));
print(json.parse("3.5"));
print(json.parse("\\"hi\\""));
`),
		["null", "false", "3.5", "hi"],
	);
});

test("json.parse: empty object and empty array", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
print(json.stringify(json.parse("{}")));
$a = json.parse("[]");
print(len(a));
print(json.stringify(a));
`),
		["{}", "0", "[]"],
	);
});

test("json.parse: invalid JSON returns an error value", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$bad = json.parse("{");
print(@isError(bad));
$bad2 = json.parse("not json");
print(@isError(bad2));
`),
		["true", "true"],
	);
});

// ---------------------------------------------------------------------------
// json.stringify — round-trips and scalars
// ---------------------------------------------------------------------------

test("json.stringify: object round-trip", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$val = json.parse("{\\"name\\": \\"Alice\\"}");
$str = json.stringify(val);
print(str);
$again = json.parse(str);
print(again.name);
`),
		[`{"name":"Alice"}`, "Alice"],
	);
});

test("json.stringify: scalars and array", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
print(json.stringify(null));
print(json.stringify(true));
print(json.stringify(42));
print(json.stringify(json.parse("[1,2,3]")));
print(json.stringify(json.parse("\\"hi\\"")));
`),
		["null", "true", "42", "[1,2,3]", `"hi"`],
	);
});

test("json.stringify: nested array round-trip", () => {
	expectOutput(
		runSource(`
@const $json = @import("std/json");
$src = "[[1,2],[3]]";
$parsed = json.parse(src);
print(parsed[0][1]);
print(parsed[1][0]);
print(json.stringify(parsed));
`),
		["2", "3", "[[1,2],[3]]"],
	);
});

// ---------------------------------------------------------------------------
// http.fetch — success, body, errors
// ---------------------------------------------------------------------------

test("http.fetch: returns 200 and body for example.com", () => {
	expectOutput(
		runSource(`
@const $http = @import("std/http");
@const $s = @import("std/string");
$res = http.fetch("http://example.com");
print(res.status);
print(s.indexOf(res.body, "Example") >= 0);
print(s.len(res.body) > 0);
`),
		["200", "true", "true"],
	);
});

test("http.fetch: invalid URL returns an error value", () => {
	expectOutput(
		runSource(`
@const $http = @import("std/http");
$err = http.fetch("not-a-url");
print(@isError(err));
print(err.code);
`),
		["true", "HttpError"],
	);
});

test("http.fetch: empty scheme / garbage is an error", () => {
	expectOutput(
		runSource(`
@const $http = @import("std/http");
print(@isError(http.fetch("")));
print(@isError(http.fetch("://")));
`),
		["true", "true"],
	);
});

test("http.request: POST request", () => {
	expectOutput(
		runSource(`
@const $http = @import("std/http");
$res = http.request("https://httpbingo.org/post", "POST", "hello");
print(res.status);
`),
		["200"],
	);
});
