/**
 * Test 58: Template literals (fenced ``` … ```).
 *
 * Contract:
 * - Open: ``` then only spaces/tabs, then newline. Content starts next line.
 * - Close: optional indent + ``` ; trailing `;` is a normal delimiter after the fence.
 * - Keep user indentation (no markdown dedent). Drop only the structural
 *   newline that ends the last body line.
 * - `${expr}` holes: a single expression only. No statements, no `$` decls,
 *   no assignments, no `;` inside the hole.
 * - Escapes in text: \n \r \t \\ \" \' \$ (same as "…" plus \$).
 * - Bare `$` not followed by `{` is a literal dollar.
 * - Desugars to string `+` (byte-slice / TString); no VM/runtime changes.
 * - `"…"` / `'…'` stay single-line. Lone 1–2 backticks are errors.
 */
import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

// ---------------------------------------------------------------------------
// ACCEPT: fences and body
// ---------------------------------------------------------------------------

test("template: single-line body drops only the structural newline", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
hi
\`\`\`;
print(s);
`),
    ["hi"],
  );
});

test("template: multi-line body keeps interior newlines and indent", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
hello
    world
\`\`\`;
print(s);
`),
    ["hello", "    world"],
  );
});

test("template: empty body is empty string", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
\`\`\`;
print(len(s));
print(s == "");
`),
    ["0", "true"],
  );
});

test("template: body with blank interior lines", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
a

b
\`\`\`;
print(s);
`),
    ["a", "", "b"],
  );
});

test("template: closing fence may be indented; indent is not body", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
body
    \`\`\`;
print(s);
`),
    ["body"],
  );
});

test("template: opening fence may be indented", () => {
  expectOutput(
    runSource(`
$s =
    \`\`\`
x
    \`\`\`;
print(s);
`),
    ["x"],
  );
});

test("template: spaces after opening ``` before newline are allowed", () => {
  expectOutput(
    runSource(`
$s = \`\`\`   
ok
\`\`\`;
print(s);
`),
    ["ok"],
  );
});

test("template: mid-line ``` does not close the fence", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
not \`\`\` close
still body
\`\`\`;
print(s);
`),
    ["not ``` close", "still body"],
  );
});

test("template: bare $ without { is a literal dollar", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
price $100 and $$ 
\`\`\`;
print(s);
`),
    ["price $100 and $$ "],
  );
});

// ---------------------------------------------------------------------------
// ACCEPT: escapes (cooked in parser)
// ---------------------------------------------------------------------------

test("template: \\n \\t \\r escapes", () => {
  // `\r` is a raw carriage return (not a line split in helpers); `\n`/`\t` as usual.
  expectOutput(
    runSource(`
$s = \`\`\`
a\\nb\\tc\\rd
\`\`\`;
print(s);
`),
    ["a", "b\tc\rd"],
  );
});

test("template: \\\\ \\\" \\' escapes", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
path=C:\\\\tmp end=\\"q\\' 
\`\`\`;
print(s);
`),
    ['path=C:\\tmp end="q\' '],
  );
});

test("template: \\$ escapes dollar so ${ is not a hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
cost: \\$5 \\\${notahole}
\`\`\`;
print(s);
`),
    ["cost: $5 ${notahole}"],
  );
});

// ---------------------------------------------------------------------------
// ACCEPT: ${…} interpolations (single expression only)
// ---------------------------------------------------------------------------

test("template: identifier hole", () => {
  expectOutput(
    runSource(`
$name = "world";
$s = \`\`\`
hello \${name}
\`\`\`;
print(s);
`),
    ["hello world"],
  );
});

test("template: arithmetic expression hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
n = \${40 + 2}
\`\`\`;
print(s);
`),
    ["n = 42"],
  );
});

test("template: multiple holes on one line", () => {
  expectOutput(
    runSource(`
$a = "L";
$b = "R";
$s = \`\`\`
\${a}|\${b}
\`\`\`;
print(s);
`),
    ["L|R"],
  );
});

test("template: function call hole", () => {
  expectOutput(
    runSource(`
@func double(n: int): int {
	return n * 2;
}
$s = \`\`\`
d=\${double(21)}
\`\`\`;
print(s);
`),
    ["d=42"],
  );
});

test("template: multi-line expression inside hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
v=\${1 +
2}
\`\`\`;
print(s);
`),
    ["v=3"],
  );
});

test("template: nested string quotes inside hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
x=\${"a}b"}
\`\`\`;
print(s);
`),
    ["x=a}b"],
  );
});

test("template: nested single-quoted string inside hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
x=\${'a}b'}
\`\`\`;
print(s);
`),
    ["x=a}b"],
  );
});

// Value @if / labeled break as hole operands desugar to string `+`. These
// cases lock the stack-temp/local-slot fix: left text must survive the break.
test("template: nested braces inside a call hole", () => {
  expectOutput(
    runSource(`
@func id(n: int): int {
	return n;
}
$s = \`\`\`
v=\${id(@if (true) { break 1; } @else { break 0; })}
\`\`\`;
print(s);
`),
    ["v=1"],
  );
});

test("template: @if expression hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
r=\${@if (true) { break "yes"; } @else { break "no"; }}
\`\`\`;
print(s);
`),
    ["r=yes"],
  );
});

test("template: labeled block expression hole", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
v=\${blk: { break :blk 7; }}
\`\`\`;
print(s);
`),
    ["v=7"],
  );
});

test("template: @if hole with text on both sides", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
[\${@if (false) { break "no"; } @else { break "yes"; }}]
\`\`\`;
print(s);
`),
    ["[yes]"],
  );
});

test("template: comparison and method call in hole", () => {
  expectOutput(
    runSource(`
@const $string = @import("std/string");
$name = "  Ada  ";
$s = \`\`\`
[\${string.trim(name)}]
\`\`\`;
print(s);
`),
    ["[Ada]"],
  );
});

test("template: hole at start and end of body", () => {
  expectOutput(
    runSource(`
$x = "A";
$y = "B";
$s = \`\`\`
\${x}mid\${y}
\`\`\`;
print(s);
`),
    ["AmidB"],
  );
});

test("template: adjacent holes with no text between", () => {
  expectOutput(
    runSource(`
$a = "1";
$b = "2";
$s = \`\`\`
\${a}\${b}
\`\`\`;
print(s);
`),
    ["12"],
  );
});

// ---------------------------------------------------------------------------
// ACCEPT: typing / declaration / use (desugar to string +)
// ---------------------------------------------------------------------------

test("template: @const without holes is a frozen string", () => {
  expectOutput(
    runSource(`
@const $m = \`\`\`
static
\`\`\`;
print(m);
print(len(m));
`),
    ["static", "6"],
  );
});

test("template: @const with only const parts still const-folds when possible", () => {
  expectOutput(
    runSource(`
@const $m = \`\`\`
n=\${1 + 1}
\`\`\`;
print(m);
`),
    ["n=2"],
  );
});

test("template: variable holds multiline string; assignment copies", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
ab
\`\`\`;
$b = s;
s = "rebound";
print(b);
print(s);
`),
    ["ab", "rebound"],
  );
});

test("template: return template from function", () => {
  expectOutput(
    runSource(`
@func greet(name: string): string {
	return \`\`\`
hi \${name}
\`\`\`;
}
print(greet("z"));
`),
    ["hi z"],
  );
});

test("template: string comparison after desugar", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
eq
\`\`\`;
print(s == "eq");
print(s != "ne");
`),
    ["true", "true"],
  );
});

test("template: len() of interpolated body", () => {
  expectOutput(
    runSource(`
$n = 12;
$s = \`\`\`
\${n}
\`\`\`;
print(len(s));
`),
    ["2"],
  );
});

test("template: use in print and string concat with +", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
T
\`\`\`;
print("pre-" + s + "-post");
`),
    ["pre-T-post"],
  );
});

test("template: assign outside template, interpolate inside", () => {
  expectOutput(
    runSource(`
$n = 1;
$s = \`\`\`
n=\${n}
\`\`\`;
print(s);
print(n);
`),
    ["n=1", "1"],
  );
});

// ---------------------------------------------------------------------------
// REJECT: fence errors
// ---------------------------------------------------------------------------

test("template: unterminated body is a compile error with fence help", () => {
  expectError(
    runSource(`
$s = \`\`\`
no close
`),
    "unterminated",
  );
});

test("template: missing newline after opening fence", () => {
  expectError(
    runSource(`
$s = \`\`\` x
hi
\`\`\`;
`),
    "newline",
  );
});

test("template: lone backtick is not a template", () => {
  expectError(
    runSource(`
$s = \`hi\`;
`),
    "backtick",
  );
});

test("template: two backticks are not a template", () => {
  expectError(
    runSource(`
$s = \`\`;
`),
    "backtick",
  );
});

test("template: unterminated ${ points at the hole", () => {
  expectError(
    runSource(`
$s = \`\`\`
x=\${1 +
\`\`\`;
`),
    "interpolation",
  );
});

// ---------------------------------------------------------------------------
// REJECT: hole grammar (single expression only)
// ---------------------------------------------------------------------------

test("template: empty ${} is rejected", () => {
  expectError(
    runSource(`
$s = \`\`\`
x=\${}
\`\`\`;
`),
    "empty",
  );
});

test("template: $ declaration inside hole is rejected", () => {
  expectError(
    runSource(`
$s = \`\`\`
\${$y = 42}
\`\`\`;
`),
    "$",
  );
});

test("template: bare assignment inside hole is rejected", () => {
  expectError(
    runSource(`
$n = 1;
$s = \`\`\`
\${n = 2}
\`\`\`;
`),
    "assignment",
  );
});

test("template: semicolon / second statement in hole is rejected", () => {
  expectError(
    runSource(`
$s = \`\`\`
\${1; 2}
\`\`\`;
`),
    "interpolation",
  );
});

test("template: compound assignment in hole is rejected", () => {
  expectError(
    runSource(`
$n = 1;
$s = \`\`\`
\${n += 1}
\`\`\`;
`),
    "assignment",
  );
});

test("template: statement keyword in hole is rejected", () => {
  expectError(
    runSource(`
$s = \`\`\`
\${return 1}
\`\`\`;
`),
    "Unexpected",
  );
});

// ---------------------------------------------------------------------------
// REJECT: templates are not used for special literal forms
// ---------------------------------------------------------------------------

test("template: not accepted as string-enum value (still string literal only)", () => {
  // Enum values still require "…" literals; a template is not a str_lit type.
  expectError(
    runSource(`
@enum Color {
	Red = \`\`\`
r
\`\`\`,
}
`),
    "",
  );
});

test("template: not used for @import path", () => {
  expectError(
    runSource(`
const string = @import(\`\`\`
std/string
\`\`\`);
print(string);
`),
    "",
  );
});

// ---------------------------------------------------------------------------
// Scanner unit-level behavior via full programs
// ---------------------------------------------------------------------------

test("template: does not break following statements", () => {
  expectOutput(
    runSource(`
$s = \`\`\`
one
\`\`\`;
$t = "two";
print(s);
print(t);
`),
    ["one", "two"],
  );
});

test("template: two templates in one function", () => {
  expectOutput(
    runSource(`
pub @func main() {
	$a = \`\`\`
A
\`\`\`;
	$b = \`\`\`
B
\`\`\`;
	print(a);
	print(b);
}
`),
    ["A", "B"],
  );
});

test("template: inside @if body", () => {
  expectOutput(
    runSource(`
@if (true) {
	$s = \`\`\`
yes
\`\`\`;
	print(s);
}
`),
    ["yes"],
  );
});

test("template: hole referencing outer local after block", () => {
  expectOutput(
    runSource(`
$n = 9;
@if (true) {
	$s = \`\`\`
n=\${n}
\`\`\`;
	print(s);
}
print(n);
`),
    ["n=9", "9"],
  );
});
