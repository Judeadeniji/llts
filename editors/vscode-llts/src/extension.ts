import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { Language, Parser, Query, type Tree } from "web-tree-sitter";

/**
 * Tree-sitter capture → VS Code semantic token type.
 * Keep this set small and map via semanticTokenScopes for theme consistency.
 */
const CAPTURE_TO_TOKEN: Record<string, string> = {
  comment: "comment",
  keyword: "keyword",
  boolean: "keyword",
  "constant.builtin": "enumMember",
  constant: "enumMember",
  string: "string",
  number: "number",
  variable: "variable",
  "variable.parameter": "parameter",
  function: "function",
  "function.method": "method",
  "function.builtin": "function",
  type: "type",
  property: "property",
  label: "variable",
  operator: "operator",
  "punctuation.bracket": "operator",
  "punctuation.delimiter": "operator",
};

/** Higher wins when several captures share the same span. */
const CAPTURE_PRIORITY: Record<string, number> = {
  comment: 10,
  keyword: 100,
  boolean: 90,
  "constant.builtin": 90,
  constant: 85,
  string: 90,
  number: 90,
  "function.builtin": 80,
  "function.method": 80,
  function: 75,
  type: 70,
  property: 65,
  "variable.parameter": 60,
  label: 55,
  variable: 40,
  operator: 30,
  "punctuation.bracket": 20,
  "punctuation.delimiter": 20,
};

const TOKEN_TYPES = [
  "comment",
  "string",
  "keyword",
  "number",
  "enumMember",
  "variable",
  "parameter",
  "function",
  "method",
  "type",
  "property",
  "operator",
] as const;

const legend = new vscode.SemanticTokensLegend([...TOKEN_TYPES], []);

let parser: Parser | undefined;
let query: Query | undefined;
let language: Language | undefined;

async function ensureParser(extensionPath: string): Promise<void> {
  if (parser && query) return;

  const media = path.join(extensionPath, "media");
  await Parser.init({
    locateFile: (scriptName: string) => path.join(media, scriptName),
  });

  language = await Language.load(path.join(media, "tree-sitter-llts.wasm"));
  parser = new Parser();
  parser.setLanguage(language);

  const highlights = fs.readFileSync(path.join(media, "highlights.scm"), "utf8");
  query = new Query(language, highlights);
}

function encodeTokens(document: vscode.TextDocument, tree: Tree): vscode.SemanticTokens {
  if (!query) {
    return new vscode.SemanticTokens(new Uint32Array());
  }

  const builder = new vscode.SemanticTokensBuilder(legend);
  const captures = query.captures(tree.rootNode);

  // Higher-priority captures win for the same span.
  const bySpan = new Map<string, { name: string; node: (typeof captures)[0]["node"] }>();
  for (const c of captures) {
    const key = `${c.node.startIndex}:${c.node.endIndex}`;
    const prev = bySpan.get(key);
    const nextPri = CAPTURE_PRIORITY[c.name] ?? 0;
    const prevPri = prev ? (CAPTURE_PRIORITY[prev.name] ?? 0) : -1;
    if (!prev || nextPri >= prevPri) {
      bySpan.set(key, c);
    }
  }

  const ranked = [...bySpan.values()].sort((a, b) => {
    if (a.node.startIndex !== b.node.startIndex) {
      return a.node.startIndex - b.node.startIndex;
    }
    return a.node.endIndex - b.node.endIndex;
  });

  for (const { name, node } of ranked) {
    const tokenType = CAPTURE_TO_TOKEN[name];
    if (!tokenType) continue;

    const typeIndex = TOKEN_TYPES.indexOf(tokenType as (typeof TOKEN_TYPES)[number]);
    if (typeIndex < 0) continue;

    const start = node.startPosition;
    const end = node.endPosition;
    if (start.row === end.row) {
      builder.push(start.row, start.column, end.column - start.column, typeIndex, 0);
    } else {
      for (let row = start.row; row <= end.row; row++) {
        const line = document.lineAt(row);
        const fromCol = row === start.row ? start.column : 0;
        const toCol = row === end.row ? end.column : line.text.length;
        if (toCol > fromCol) {
          builder.push(row, fromCol, toCol - fromCol, typeIndex, 0);
        }
      }
    }
  }

  return builder.build();
}

class LltsSemanticTokensProvider implements vscode.DocumentSemanticTokensProvider {
  private readonly trees = new Map<string, Tree>();

  constructor(private readonly extensionPath: string) {}

  async provideDocumentSemanticTokens(
    document: vscode.TextDocument,
  ): Promise<vscode.SemanticTokens> {
    await ensureParser(this.extensionPath);
    if (!parser) {
      return new vscode.SemanticTokens(new Uint32Array());
    }

    const key = document.uri.toString();
    this.trees.get(key)?.delete();
    const tree = parser.parse(document.getText());
    if (!tree) {
      return new vscode.SemanticTokens(new Uint32Array());
    }
    this.trees.set(key, tree);
    return encodeTokens(document, tree);
  }

  disposeDocument(uri: vscode.Uri): void {
    const key = uri.toString();
    this.trees.get(key)?.delete();
    this.trees.delete(key);
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const provider = new LltsSemanticTokensProvider(context.extensionPath);

  context.subscriptions.push(
    vscode.languages.registerDocumentSemanticTokensProvider(
      { language: "llts" },
      provider,
      legend,
    ),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      if (doc.languageId === "llts") provider.disposeDocument(doc.uri);
    }),
  );

  void ensureParser(context.extensionPath).catch((err) => {
    void vscode.window.showErrorMessage(
      `LLTS Tree-sitter failed to load: ${err instanceof Error ? err.message : err}`,
    );
  });
}

export function deactivate(): void {
  parser?.delete();
  language = undefined;
  parser = undefined;
  query = undefined;
}
