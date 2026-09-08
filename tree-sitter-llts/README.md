# tree-sitter-llts

Tree-sitter grammar for [LLTS](../README.md) (`.lls`), authored as TypeScript-checked `grammar.js`.

## Setup

```bash
cd tree-sitter-llts
bun install
bun run generate
bun run test
```

Requires a C compiler for `tree-sitter test` / `tree-sitter build`.

## Scripts

| Script | Action |
|--------|--------|
| `bun run generate` | Regenerate parser from `grammar.js` |
| `bun run test` | Run corpus tests + validate highlight queries |
| `bun run parse -- ../examples/showcase.lls` | Parse a file |
| `bunx tree-sitter build --wasm` | Build WASM for the VS Code / Cursor extension |

## Status

Corpus tests pass. Parses **all 37** files under `examples/` cleanly.

## VS Code / Cursor

See [`../editors/vscode-llts`](../editors/vscode-llts) for the semantic-highlighting extension that loads this grammar’s WASM + `highlights.scm`.

- `grammar.js` — grammar DSL (`/// <reference types="tree-sitter-cli/dsl" />` + `@ts-check`)
- `queries/highlights.scm` — highlighting queries
- `test/corpus/` — expected parse trees
- `src/` — generated parser (`parser.c`, etc.)

## Editors

Neovim / Helix can load this parser + `queries/highlights.scm`. VS Code / Cursor need a Tree-sitter extension (or a TextMate grammar) for default highlighting.
