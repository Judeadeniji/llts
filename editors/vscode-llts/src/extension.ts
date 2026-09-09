import { startLsp, stopLsp } from "./lspClient";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import { Language, Parser, Query, type Node, type Tree } from "web-tree-sitter";

/**
 * Tree-sitter is the only highlighter. Colors are applied as editor decorations
 * with explicit foregrounds so we do not depend on theme semantic/TextMate rules.
 */

/** Higher wins when several captures share the same span. */
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

/** Capture → decoration bucket (related operators share a style). */
const CAPTURE_TO_STYLE: Record<string, string> = {
  comment: "comment",
  keyword: "keyword",
  boolean: "keyword",
  "constant.builtin": "constant",
  constant: "constant",
  string: "string",
  number: "number",
  variable: "variable",
  "variable.parameter": "parameter",
  label: "label",
  module: "module",
  function: "function",
  "function.method": "method",
  "function.builtin": "function",
  type: "type",
  property: "property",
  operator: "operator",
  "operator.unary": "operator",
  "operator.range": "operator",
  "operator.spread": "operator",
};

/** Dark+-inspired palette; applied directly (theme-independent). */
const STYLE_COLORS: Record<string, string> = {
  comment: "#6A9955",
  keyword: "#C586C0",
  constant: "#4FC1FF",
  string: "#CE9178",
  number: "#B5CEA8",
  variable: "#9CDCFE",
  parameter: "#9CDCFE",
  label: "#C8C8C8",
  module: "#4EC9B0",
  function: "#DCDCAA",
  method: "#DCDCAA",
  type: "#4EC9B0",
  property: "#9CDCFE",
  operator: "#D7BA7D",
  /** `{` `}` in format strings */
  formatBrace: "#D7BA7D",
  /** `i` / `s` inside `{i}` */
  formatSpec: "#B5CEA8",
};

const FORMAT_PLACEHOLDER = /\{([A-Za-z_][A-Za-z0-9_]*)\}/g;

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

function mergeCaptures(
  captures: Array<{ name: string; node: Node }>,
): Array<{ name: string; node: Node }> {
  const bySpan = new Map<string, { name: string; node: Node }>();
  for (const c of captures) {
    if (c.name.startsWith("punctuation.")) continue;
    if (!CAPTURE_TO_STYLE[c.name]) continue;

    const key = `${c.node.startIndex}:${c.node.endIndex}`;
    const prev = bySpan.get(key);
    const nextPri = CAPTURE_PRIORITY[c.name] ?? 0;
    const prevPri = prev ? (CAPTURE_PRIORITY[prev.name] ?? 0) : -1;
    if (!prev || nextPri >= prevPri) {
      bySpan.set(key, c);
    }
  }
  return [...bySpan.values()];
}

function rangeFromNode(node: Node): vscode.Range {
  return new vscode.Range(
    node.startPosition.row,
    node.startPosition.column,
    node.endPosition.row,
    node.endPosition.column,
  );
}

function rangeFromOffsets(
  document: vscode.TextDocument,
  start: number,
  end: number,
): vscode.Range {
  return new vscode.Range(document.positionAt(start), document.positionAt(end));
}

/** Split a string literal into string / `{` / spec / `}` ranges for format placeholders. */
function paintFormatString(
  document: vscode.TextDocument,
  node: Node,
  rangesByStyle: Map<string, vscode.Range[]>,
): void {
  const text = node.text;
  const base = node.startIndex;
  FORMAT_PLACEHOLDER.lastIndex = 0;

  const push = (style: string, from: number, to: number) => {
    if (to <= from) return;
    rangesByStyle.get(style)?.push(rangeFromOffsets(document, from, to));
  };

  let last = 0;
  let match: RegExpExecArray | null;
  let found = false;
  while ((match = FORMAT_PLACEHOLDER.exec(text)) !== null) {
    found = true;
    const start = match.index;
    const spec = match[1]!;
    push("string", base + last, base + start);
    push("formatBrace", base + start, base + start + 1);
    push("formatSpec", base + start + 1, base + start + 1 + spec.length);
    push("formatBrace", base + start + 1 + spec.length, base + start + match[0].length);
    last = start + match[0].length;
  }

  if (!found) {
    push("string", base, base + text.length);
    return;
  }
  push("string", base + last, base + text.length);
}

class LltsHighlighter implements vscode.Disposable {
  private readonly decorations = new Map<string, vscode.TextEditorDecorationType>();
  private readonly trees = new Map<string, Tree>();
  private readonly debounce = new Map<string, NodeJS.Timeout>();
  private ready = false;

  constructor(private readonly extensionPath: string) {
    for (const [style, color] of Object.entries(STYLE_COLORS)) {
      this.decorations.set(
        style,
        vscode.window.createTextEditorDecorationType({ color }),
      );
    }
  }

  async init(): Promise<void> {
    await ensureParser(this.extensionPath);
    this.ready = true;
  }

  dispose(): void {
    for (const t of this.debounce.values()) clearTimeout(t);
    this.debounce.clear();
    for (const tree of this.trees.values()) tree.delete();
    this.trees.clear();
    for (const d of this.decorations.values()) d.dispose();
    this.decorations.clear();
  }

  schedule(document: vscode.TextDocument): void {
    if (document.languageId !== "llts") return;
    const key = document.uri.toString();
    const prev = this.debounce.get(key);
    if (prev) clearTimeout(prev);
    this.debounce.set(
      key,
      setTimeout(() => {
        this.debounce.delete(key);
        void this.paint(document);
      }, 40),
    );
  }

  clear(document: vscode.TextDocument): void {
    const key = document.uri.toString();
    this.trees.get(key)?.delete();
    this.trees.delete(key);
    for (const editor of vscode.window.visibleTextEditors) {
      if (editor.document.uri.toString() !== key) continue;
      for (const deco of this.decorations.values()) {
        editor.setDecorations(deco, []);
      }
    }
  }

  getTree(document: vscode.TextDocument): Tree | undefined {
    return this.trees.get(document.uri.toString());
  }

  private async paint(document: vscode.TextDocument): Promise<void> {
    if (!this.ready) {
      try {
        await this.init();
      } catch (err) {
        void vscode.window.showErrorMessage(
          `LLTS Tree-sitter failed to load: ${err instanceof Error ? err.message : err}`,
        );
        return;
      }
    }
    if (!parser || !query) return;

    const key = document.uri.toString();
    this.trees.get(key)?.delete();
    const tree = parser.parse(document.getText());
    if (!tree) return;
    this.trees.set(key, tree);

    const merged = mergeCaptures(query.captures(tree.rootNode));
    const rangesByStyle = new Map<string, vscode.Range[]>();
    for (const style of this.decorations.keys()) {
      rangesByStyle.set(style, []);
    }

    for (const { name, node } of merged) {
      if (node.startIndex >= node.endIndex) continue;

      if (name === "string") {
        paintFormatString(document, node, rangesByStyle);
        continue;
      }

      const style = CAPTURE_TO_STYLE[name];
      if (!style) continue;
      rangesByStyle.get(style)?.push(rangeFromNode(node));
    }

    for (const editor of vscode.window.visibleTextEditors) {
      if (editor.document.uri.toString() !== key) continue;
      for (const [style, deco] of this.decorations) {
        editor.setDecorations(deco, rangesByStyle.get(style) ?? []);
      }
    }
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const highlighter = new LltsHighlighter(context.extensionPath);
  context.subscriptions.push(highlighter);

  void highlighter.init().then(() => {
    for (const editor of vscode.window.visibleTextEditors) {
      highlighter.schedule(editor.document);
    }
  });

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((doc) => highlighter.schedule(doc)),
    vscode.workspace.onDidChangeTextDocument((e) => highlighter.schedule(e.document)),
    vscode.workspace.onDidCloseTextDocument((doc) => highlighter.clear(doc)),
    vscode.window.onDidChangeVisibleTextEditors((editors) => {
      for (const editor of editors) highlighter.schedule(editor.document);
    }),
  );

  context.subscriptions.push(
    vscode.languages.registerDocumentSymbolProvider(
      { language: "llts" },
      new LltsDocumentSymbolProvider(highlighter)
    )
  );

  startLsp(context);
}

class LltsDocumentSymbolProvider implements vscode.DocumentSymbolProvider {
  constructor(private readonly highlighter: LltsHighlighter) {}

  provideDocumentSymbols(
    document: vscode.TextDocument,
    token: vscode.CancellationToken
  ): vscode.ProviderResult<vscode.DocumentSymbol[] | vscode.SymbolInformation[]> {
    const tree = this.highlighter.getTree(document);
    if (!tree) return [];

    const symbols: vscode.DocumentSymbol[] = [];

    function traverse(node: Node, container: vscode.DocumentSymbol[]) {
      let symbol: vscode.DocumentSymbol | undefined;

      try {
        switch (node.type) {
          case "func_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "function",
                vscode.SymbolKind.Function,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "struct_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "struct",
                vscode.SymbolKind.Struct,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "enum_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "enum",
                vscode.SymbolKind.Enum,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "error_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "error",
                vscode.SymbolKind.Enum,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "const_declaration":
          case "variable_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                node.type === "const_declaration" ? "const" : "variable",
                vscode.SymbolKind.Variable,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "type_declaration":
          case "alias_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "type",
                vscode.SymbolKind.Class,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "struct_field": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "field",
                vscode.SymbolKind.Field,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "enum_variant": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "variant",
                vscode.SymbolKind.EnumMember,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "extern_declaration": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "extern",
                vscode.SymbolKind.Function,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
          case "labeled_expression": {
            const nameNode = node.childForFieldName("label");
            if (nameNode && nameNode.text) {
              let selectionRange = rangeFromNode(nameNode);
              let fullRange = rangeFromNode(node);
              // Ensure selection is contained in fullRange to prevent VS Code from throwing
              if (selectionRange.start.isBefore(fullRange.start)) fullRange = new vscode.Range(selectionRange.start, fullRange.end);
              if (selectionRange.end.isAfter(fullRange.end)) fullRange = new vscode.Range(fullRange.start, selectionRange.end);
              
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "label",
                vscode.SymbolKind.Key,
                fullRange,
                selectionRange
              );
            }
            break;
          }
          case "parameter": {
            const nameNode = node.childForFieldName("name");
            if (nameNode && nameNode.text) {
              symbol = new vscode.DocumentSymbol(
                nameNode.text,
                "parameter",
                vscode.SymbolKind.Variable,
                rangeFromNode(node),
                rangeFromNode(nameNode)
              );
            }
            break;
          }
        }
      } catch (err) {
        console.error("Failed to create document symbol for node", node.type, err);
      }

      const targetContainer = symbol ? symbol.children : container;
      if (symbol) {
        container.push(symbol);
      }

      for (let i = 0; i < node.childCount; i++) {
        const child = node.child(i);
        if (child) traverse(child, targetContainer);
      }
    }

    traverse(tree.rootNode, symbols);
    return symbols;
  }
}

export function deactivate(): Thenable<void> | undefined {
  parser?.delete();
  language = undefined;
  parser = undefined;
  query = undefined;
  return stopLsp();
}
