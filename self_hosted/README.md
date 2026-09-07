# Self-hosted LLTS

1:1 port of the Zig compiler toolchain ([`src/`](../src/)) to LLTS, run on the host Zig VM.

## Goals

- Prove LLTS can express its own compiler (language forcing function).
- Mirror `src/` module layout and logic; map Zig std containers to LLTS `std/` (list/map/buffer/Arena).
- When Zig is incomplete, stubbed, or wrong: **fix Zig → land on `main` → continue the port**.
- When LLTS cannot say something cleanly: add the language/std capability (with tests), then use it here.

## Status

| Module | Status |
|--------|--------|
| `shared/ops` | done |
| `scanner/` | done (parity harness vs Zig tokenizer; `scan(arena, source, path)`) |
| `ast/` | types + smoke (`tools/ast_smoke.lls`); child links are `unknown` (*Node) until forward refs land |
| `parser/`, `bytecode/`, `compiler/`, `cli/` | not started |
| `vm/` | deferred (host Zig VM executes `.llb`) |

Known Zig gaps hit during this port (fixed or worked around):
- Array literal trailing commas (fixed in `src/parser/expr.zig`)
- Module rewrite of function param types (fixed in `src/compiler/modules.zig`)
- `self.method()` reachability for free `self: *T` (fixed in call graph)
- `@if (opt) \|t\|` capture typing for struct fields (fixed in `compileIf`)
- Host `std/list` / `map` / `buffer` immortal host heap (fixed: arena-backed; `create(arena)`)

Known LLTS gaps (documented, continue with workarounds):
- No forward reference into `@type` union arms → AST children typed `unknown`
- Packing structs into `std/list` across modules → scanner uses parallel lists

## Harness

From repo root (after `zig build`):

```bash
# LLTS tokenizer
./zig-out/bin/llts run self_hosted/tools/tokenize.lls examples/hello-world.lls

# Zig reference tokenizer (same line format)
./zig-out/bin/llts-tokenize-zig examples/hello-world.lls

# Diff
diff <(./zig-out/bin/llts-tokenize-zig examples/hello-world.lls) \
     <(./zig-out/bin/llts run self_hosted/tools/tokenize.lls examples/hello-world.lls)
```

Token line format: `type<TAB>value<TAB>line:column`

## Idiom map

| Zig | LLTS |
|-----|------|
| `Allocator` / ArenaAllocator | `std/mem.Arena` |
| `ArrayList(u8)` | `std/buffer` |
| `ArrayList(T)` | `std/list` (`create(arena)`) |
| `StringHashMap` | `std/map` (`create(arena)`) |
| `std.fmt` | `string` + `buffer` |
| `!T` / `errdefer` | `error(...)` / `?` / `errdefer` |
| `union(enum)` | `@enum` + structs + `@type` unions |
| `@tagName(e)` | `@nameOf(e)` (enum or error; spelling as declared) |
| zli CLI | manual `os.args()` |
