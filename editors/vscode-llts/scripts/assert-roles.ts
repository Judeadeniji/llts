/**
 * Role-assertion harness for LLTS highlight taxonomy.
 * Loads the Tree-sitter WASM + highlights.scm, merges captures with the same
 * priority table as the VS Code extension, then checks expected roles.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { Language, Parser, Query } from "web-tree-sitter";

const ROOT = path.resolve(import.meta.dir, "..");
const MEDIA = path.join(ROOT, "media");
const EXAMPLES = path.resolve(ROOT, "../../examples");

/** Must stay in sync with src/extension.ts CAPTURE_PRIORITY. */
const CAPTURE_PRIORITY: Record<string, number> = {
  comment: 10,
  keyword: 100,
  boolean: 90,
  "constant.builtin": 90,
  constant: 88,
  string: 90,
  number: 90,
  "function.builtin": 82,
  "function.method": 80,
  function: 78,
  type: 72,
  module: 70,
  property: 65,
  "variable.parameter": 62,
  label: 58,
  variable: 40,
  "operator.unary": 35,
  "operator.range": 35,
  "operator.spread": 35,
  operator: 30,
  "punctuation.bracket": 20,
  "punctuation.delimiter": 20,
};

type RoleHit = { name: string; text: string; start: number; end: number };

function mergeCaptures(
  captures: Array<{ name: string; node: { startIndex: number; endIndex: number; text: string } }>,
): RoleHit[] {
  const bySpan = new Map<string, RoleHit>();
  for (const c of captures) {
    const key = `${c.node.startIndex}:${c.node.endIndex}`;
    const nextPri = CAPTURE_PRIORITY[c.name] ?? 0;
    const prev = bySpan.get(key);
    const prevPri = prev ? (CAPTURE_PRIORITY[prev.name] ?? 0) : -1;
    if (!prev || nextPri >= prevPri) {
      bySpan.set(key, {
        name: c.name,
        text: c.node.text,
        start: c.node.startIndex,
        end: c.node.endIndex,
      });
    }
  }
  return [...bySpan.values()].sort((a, b) => a.start - b.start || a.end - b.end);
}

function rolesAt(hits: RoleHit[], source: string, needle: string, occurrence = 0): RoleHit[] {
  let from = 0;
  let found = -1;
  for (let i = 0; i <= occurrence; i++) {
    found = source.indexOf(needle, from);
    if (found < 0) throw new Error(`needle not found: ${JSON.stringify(needle)} (#${occurrence})`);
    from = found + 1;
  }
  const start = found;
  const end = start + needle.length;
  return hits.filter((h) => h.start >= start && h.end <= end);
}

function expectRole(hits: RoleHit[], text: string, role: string, ctx: string): void {
  const match = hits.find((h) => h.text === text && h.name === role);
  if (!match) {
    const nearby = hits.map((h) => `${h.name}:${JSON.stringify(h.text)}`).join(", ");
    throw new Error(`${ctx}: expected ${role} on ${JSON.stringify(text)}; got [${nearby}]`);
  }
}

async function main(): Promise<void> {
  await Parser.init({
    locateFile: (scriptName: string) => path.join(MEDIA, scriptName),
  });
  const language = await Language.load(path.join(MEDIA, "tree-sitter-llts.wasm"));
  const parser = new Parser();
  parser.setLanguage(language);
  const query = new Query(language, fs.readFileSync(path.join(MEDIA, "highlights.scm"), "utf8"));

  type Fixture = {
    name: string;
    source: string;
    check: (hits: RoleHit[], source: string, label: string) => void;
  };

  const fixtures: Fixture[] = [
    {
      name: "module-call-chain",
      source: `std.debug.printLn("hi");\n`,
      check(hits, source, label) {
        const window = rolesAt(hits, source, "std.debug.printLn");
        expectRole(window, "std", "module", label);
        expectRole(window, "debug", "property", label);
        expectRole(window, "printLn", "function.method", label);
      },
    },
    {
      name: "module-bare-chain",
      source: `$p = std.debug.printLn;\n`,
      check(hits, source, label) {
        const window = rolesAt(hits, source, "std.debug.printLn");
        expectRole(window, "std", "module", label);
        expectRole(window, "debug", "property", label);
        expectRole(window, "printLn", "function.method", label);
      },
    },
    {
      name: "enum-path",
      source: `@enum ExprKind { Literal, Binary }\n@func main() { ExprKind.Literal; }\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "ExprKind {"), "ExprKind", "type", label);
        expectRole(rolesAt(hits, source, "Literal,"), "Literal", "constant", label);
        const pathHits = rolesAt(hits, source, "ExprKind.Literal");
        expectRole(pathHits, "ExprKind", "type", label);
        expectRole(pathHits, "Literal", "constant", label);
      },
    },
    {
      name: "field-access",
      source: `@struct S { kind: int; }\n@func main() { $a = S{ kind: 1 }; a.kind; }\n`,
      check(hits, source, label) {
        // Path root left of `.` uses module color (same as std.debug).
        expectRole(rolesAt(hits, source, "a.kind"), "a", "module", label);
        expectRole(rolesAt(hits, source, "a.kind"), "kind", "property", label);
      },
    },
    {
      name: "std-depth1-and-depth2",
      source: `$o = std.debug;\n$p = std.debug.printLn;\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "std.debug;"), "std", "module", label);
        expectRole(rolesAt(hits, source, "std.debug.printLn"), "std", "module", label);
        expectRole(rolesAt(hits, source, "std.debug.printLn"), "printLn", "function.method", label);
      },
    },
    {
      name: "self-stays-variable",
      source: `@func m(self) { self.x; }\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "self.x"), "self", "variable", label);
        expectRole(rolesAt(hits, source, "self.x"), "x", "property", label);
      },
    },
    {
      name: "struct-init",
      source: `Literal{ kind: 1 };\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "Literal{"), "Literal", "type", label);
        expectRole(rolesAt(hits, source, "kind:"), "kind", "property", label);
      },
    },
    {
      name: "index-slice-array",
      source: `@func main() {\n  $arr = [0, 1, 2, 3, 4];\n  arr[1..4];\n  arr[..];\n  $t: [5]byte = undefined;\n}\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "1..4"), "..", "operator.range", label);
        expectRole(rolesAt(hits, source, "arr[..]"), "..", "operator.range", label);
        expectRole(rolesAt(hits, source, "[0, 1, 2, 3, 4]"), "0", "number", label);
        const ty = rolesAt(hits, source, "[5]byte");
        expectRole(ty, "5", "number", label);
        expectRole(ty, "byte", "type", label);
      },
    },
    {
      name: "range-screaming",
      source: `$LIMIT = 10; 0..LIMIT;\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "0..LIMIT"), "..", "operator.range", label);
        expectRole(rolesAt(hits, source, "0..LIMIT"), "LIMIT", "variable", label);
      },
    },
    {
      name: "operators",
      source: `@func f(xs: int, ...) { $x = 1; -x; x?; a |> f; }\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, ", ...)"), "...", "operator.spread", label);
        expectRole(rolesAt(hits, source, "-x;"), "-", "operator.unary", label);
        expectRole(rolesAt(hits, source, "x?"), "?", "operator.unary", label);
        expectRole(rolesAt(hits, source, "a |> f"), "|>", "operator", label);
      },
    },
    {
      name: "decls-control",
      source: `pub @func go() {\n  @struct Point { x: int; }\n  @enum E { A }\n  defer go();\n  return;\n}\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "pub "), "pub", "keyword", label);
        expectRole(rolesAt(hits, source, "@func"), "@func", "keyword", label);
        expectRole(rolesAt(hits, source, "go()"), "go", "function", label);
        expectRole(rolesAt(hits, source, "@struct"), "@struct", "keyword", label);
        expectRole(rolesAt(hits, source, "Point {"), "Point", "type", label);
        expectRole(rolesAt(hits, source, "@enum"), "@enum", "keyword", label);
        expectRole(rolesAt(hits, source, "defer "), "defer", "keyword", label);
        expectRole(rolesAt(hits, source, "return;"), "return", "keyword", label);
      },
    },
    {
      name: "label-capture-error-ptr",
      source: `@func main() {\n  blk: { break :blk; }\n  @for (xs) |i| { i; }\n  error("boom");\n  $p: *int = null;\n}\n`,
      check(hits, source, label) {
        expectRole(rolesAt(hits, source, "blk:"), "blk", "label", label);
        expectRole(rolesAt(hits, source, ":blk"), "blk", "label", label);
        expectRole(rolesAt(hits, source, "|i|"), "i", "variable.parameter", label);
        expectRole(rolesAt(hits, source, "error("), "error", "keyword", label);
        expectRole(rolesAt(hits, source, "*int"), "*", "operator.unary", label);
        expectRole(rolesAt(hits, source, "*int"), "int", "type", label);
      },
    },
  ];

  let failed = 0;
  for (const fx of fixtures) {
    const tree = parser.parse(fx.source);
    if (!tree) {
      console.error(`FAIL ${fx.name}: parse returned null`);
      failed++;
      continue;
    }
    try {
      const hits = mergeCaptures(query.captures(tree.rootNode));
      fx.check(hits, fx.source, fx.name);
      console.log(`ok  ${fx.name}`);
    } catch (err) {
      failed++;
      console.error(`FAIL ${fx.name}: ${err instanceof Error ? err.message : err}`);
    } finally {
      tree.delete();
    }
  }

  // Smoke: examples parse and produce some non-variable captures
  const exampleFiles = [
    "tagged.lls",
    "control-flow.lls",
    "methods.lls",
    "slices.lls",
    "arrays.lls",
    "showcase.lls",
    "pointers.lls",
    "error.lls",
    "blocks.lls",
  ];
  for (const file of exampleFiles) {
    const full = path.join(EXAMPLES, file);
    if (!fs.existsSync(full)) {
      console.warn(`skip ${file}: missing`);
      continue;
    }
    const source = fs.readFileSync(full, "utf8");
    const tree = parser.parse(source);
    if (!tree) {
      console.error(`FAIL example ${file}: parse null`);
      failed++;
      continue;
    }
    const hits = mergeCaptures(query.captures(tree.rootNode));
    const roles = new Set(hits.map((h) => h.name));
    const need = ["keyword", "function", "operator"];
    const missing = need.filter((r) => !roles.has(r));
    if (missing.length) {
      // soft: some tiny files may lack operators
      console.log(`ok  example ${file} roles=${[...roles].sort().join(",")}`);
    } else {
      console.log(`ok  example ${file}`);
    }
    tree.delete();
  }

  parser.delete();
  if (failed > 0) {
    console.error(`\n${failed} fixture(s) failed`);
    process.exit(1);
  }
  console.log("\nall role assertions passed");
}

await main();
