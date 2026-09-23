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

Reload the window, open any `.lls` file. Tree-sitter provides the coloring; semantic highlighting stays off for `[llts]`.

## Language server

The extension speaks to the Zig language server (`llts-lsp`) for diagnostics, hover, and go-to-definition. The binary is resolved in this order:

1. The `llts.serverPath` setting (relative paths resolve against the workspace root, `~` is expanded)
2. `<workspace>/zig-out/bin/llts-lsp` — the repo's build output, so `zig build` is all you need
3. The binary bundled with the extension (`bin/llts-lsp`)

If none is found, an error explains how to build or point at one.

```bash
# from the repo root — rebuild the server after pulling changes
zig build
```

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
| `src/extension.ts` | Tree-sitter highlighting + document symbols |
| `src/lspClient.ts` | Language server lifecycle + binary resolution |
| `bin/llts-lsp` | Bundled fallback server binary |
