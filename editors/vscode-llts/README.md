# LLTS for VS Code / Cursor

Tree-sitter highlighting for `.lls` files, with a TextMate base grammar so themes color variables/types consistently.

## Install (local)

```bash
cd editors/vscode-llts
bun install
bun run compile
```

Then in Cursor / VS Code:

1. **Extensions: Install from VSIX…** after `bun run package`, or
2. Open this folder and press **F5** (Extension Development Host), or
3. Symlink into your extensions dir:

```bash
# Cursor
ln -s "$(pwd)" ~/.cursor/extensions/llts.llts-0.1.0

# VS Code
ln -s "$(pwd)" ~/.vscode/extensions/llts.llts-0.1.0
```

Reload the window, open any `.lls` file. Confirm `editor.semanticHighlighting.enabled` is on (default for `[llts]`).

## Rebuild grammar WASM

```bash
cd tree-sitter-llts
bun run generate
bunx tree-sitter build --wasm
cp tree-sitter-llts.wasm ../editors/vscode-llts/media/
cp queries/highlights.scm ../editors/vscode-llts/media/
```

## Layout

| Path | Role |
|------|------|
| `media/tree-sitter-llts.wasm` | Language grammar |
| `media/tree-sitter.wasm` | web-tree-sitter runtime |
| `media/highlights.scm` | Highlight queries |
| `src/extension.ts` | Semantic tokens provider |
