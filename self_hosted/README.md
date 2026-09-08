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
| `ast/` | `common` + `nodes` (`*Node` children) + Document; smoke in `tools/ast_smoke.lls` |
| `parser/` | done (expr/postfix/stmt/decl/control/types/structs/enums/errors); `parse` → Document; smoke fixture |
| `bytecode/` | `opcode` + `chunk` (consts/globals/funcs/jumps) + serialize v3 |
| `compiler/` | emit growing toward Zig 1:1 — not there yet; see gaps below |
| `cli/` | not started |
| `vm/` | deferred (host Zig VM executes `.llb`) |

**Gate:** point at full `examples/` only when `./self_hosted/tools/examples_smoke.sh all` is green (Zig emit parity). Until then the curated list is a progress ladder only.

Known Zig gaps hit during this port (fixed or worked around):
- Array literal trailing commas (fixed in `src/parser/expr.zig`)
- Module rewrite of function param types (fixed in `src/compiler/modules.zig`)
- `self.method()` reachability for free `self: *T` (fixed in call graph)
- `@if (opt) \|t\|` capture typing for struct fields (fixed in `compileIf`)
- Host `std/list` / `map` / `buffer` immortal host heap (fixed: arena-backed; `create(arena)`)
- Forward `@type` names + covariant `*Arm ⊑ *Union` (fixed in typechecker / typedef stubs)
- Module rewrite of `@type` union/pointer type AST (fixed in `rewriteRefs`)
- Functions returning `@new` typed as `*T` (fixed in analyzeBody)
- Return paths via `error(...)` / `fail()` widen `T` → `T | error` (refineErrorReturns)
- `break value` in `@switch` is not an error-discard warning

Known LLTS / host-emit gaps (documented, continue with workarounds):
- Cross-module circular `*other.Node` still weak — keep Node arms + `@type Node` in one module
- Packing structs into `std/list` across modules → scanner uses parallel lists
- `$` register names share one type across a module (and collide when modules compile together) — use unique names per role (`$labFor` vs `$pubFn`, `em*` in the compiler)
- Multiple `emExpr(...)` call sites in one function → host panic (`integer does not fit`)
- `os.args()` or `@import("std/fs")` in the same program as `self_hosted/compiler` → host panic; examples harness uses a shell driver + `__readFile` path file
- Growing newly reachable helpers past a cliff (extra `@func` called from emit) → host panic

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

Self-hosted emit progress (not full Zig parity yet):

```bash
./zig-out/bin/llts run self_hosted/tools/compile_smoke.lls
# Curated ladder / full examples/ (shell driver — see host gaps above):
./self_hosted/tools/examples_smoke.sh
./self_hosted/tools/examples_smoke.sh all
```

Still missing vs Zig emit: imports/modules/std, arrays/slices/iter-for, enums/switch, errors/try/defer, many intrinsics, typecheck/reachability, …

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
