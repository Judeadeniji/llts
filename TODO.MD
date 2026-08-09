# LLTS Project Status & Roadmap

Zig implementation. The TypeScript prototype/reference is [`llts-js`](../llts-js).

## ✅ Current Capabilities

### Lexer (Scanner)
- [x] Basic Tokens: Identifiers, Numbers (int, float, hex, binary, octal), Strings, Booleans.
- [x] Registers: `$a`, `$t0`, etc. (declaration-only sigil; uses omit `$`).
- [x] Keywords: `return`, `true`, `false`, `break`, `continue`, `pub`, `defer`.
- [x] Compiler Directives: `@func`, `@import`, `@const`, `@if`, `@for`, `@struct`, `@typeOf`, `@isError`, `@extern`.
- [x] Operators: Arithmetic, Assignment (including compound `+=` etc.), Comparison, Logical, Pipe (`|>`), Power (`**` / `^`).
- [x] Comments: Line comments starting with `#`.

### Parser
- [x] Function Declarations: `@func name(params): type { body }`.
- [x] Variable Declarations: `$var = value`, `@const $var = value`.
- [x] Expressions: Binary, Unary, Call, Member access, Pipe (`|>`), Index (`[]`).
- [x] Control Flow: `@if`/`@else`, `@for` (range `0..N`, condition, and iterable forms).
- [x] Loops: `break`, `continue`, labeled loops (`outer: @for … break :outer`).
- [x] Structs: `@struct` with fields and methods.
- [x] Arrays: Array literals `[a, b, c]` and index access `arr[i]` (incl. nested).
- [x] Imports: `@import("path")` with module namespacing and `pub` exports.
- [x] Explicit errors for unsupported / invalid syntax.

### Compiler & VM
- [x] Bytecode generation and stack execution.
- [x] `OP_CALL_STATIC` / dynamic `OP_CALL` for first-class functions.
- [x] Return-type tracking for fluent method chaining.
- [x] Struct heap allocation, field offsets, method dispatch.
- [x] Module import system (`module:` bindings, `OP_GET_MODULE`).
- [x] Dynamic property get/set on module objects.
- [x] Mutual recursion + call graph cycle detection.
- [x] Gradual typecheck + `@typeOf`; `--release` strips debug type asserts.

### Standard Library (`std/`) — optional library, not language core
- Imports use explicit paths (e.g. `@import("std/math")`); no short-name aliases in the compiler.
- [x] `std/math`: `add`, `sub`, `mul`, `div`, `mod`, `pow`, `sqr`, `min`, `max`, `abs`, `floor`, `ceil`, …
- [x] `std/string`: `len`, `concat`, `substr`, `indexOf`, `split`, case/trim/replace/…
- [x] `std/debug`: `printLn`, `log`, `assert`.
- [x] `std/mem`: `alloc` / Arena helpers.
- [x] `std/io`: `readLine`, `readFile`, `writeFile`, `appendFile`, `deleteFile`, `exists` via host `__*` bindings.

### Tooling
- [x] `zig build` / `zig build test`.
- [x] Language conformance suite under `tests/*.test.ts` (Bun runner, Zig binary).
- [x] Runtime stack traces and source-context diagnostics on stderr.

---

## 🚧 Roadmap — Ordered by Priority

### P0 — Silent Wrong Behaviour (no error, wrong result)

- [x] **Hex / binary / octal literals**
- [x] **`^` / `**` exponent**
- [x] **Unary `+`** — identity operator.

### P1 — Missing Language Features

- [x] **Explicit error handling** — `error(msg)` and `?`.
- [x] **`@const` enforcement** — reassignment is a compile / runtime error.
- [x] **`@const` initializers** — compile-time constant expressions only.

### P2 — Standard Library

- [x] **String operations** — in `std/string.lls` + native bindings.
- [x] **Real `std.io`** — stdin / disk via `__*` natives.
- [x] **Math extras** — `min`, `max`, `abs`, `floor`, `ceil`, etc.

### P3 — Safety & Correctness

- [x] **Array bounds checking**
- [x] **`@const` at VM level**
- [x] **LLTS source locations in runtime errors**

### P4 — Type System

- [x] **Type checker pass** — gradual analysis before emit (`src/compiler/typecheck/`).
- [x] **Return / param / field annotations** when present; unannotated = `Unknown`.
- [x] **`$name: T`**, `[]T` / `[N]T` (incl. nested), `T | error`; aliases `i32`/`number`→`int`, `boolean`→`bool`.
- [x] **`string` ≡ `[]byte`**; string literals infer as `[N]byte`.
- [x] **Structs as types**
- [x] **Debug type asserts**; strip with `--release`.
- [x] **`@typeOf(expr)`**
- [x] **`pub` for user files** — private decls stay in-module; relative `./` / `../` imports.

### P5 — Memory

- [x] **Arenas + allocators** — `Arena` create / alloc / reset / deinit.
- [x] **`defer`** — LIFO scope-exit cleanup; `errdefer` later if needed.
- [x] **No tracing GC** — ownership is explicit (allocator + defer).

### P6 — Tooling

- [ ] **Broader test coverage** — more Zig unit/integration cases for parser, compiler, and VM edge paths.
- [x] **Runtime stack traces** — LLTS call stacks on stderr with source context.
- [ ] **CLI improvements** — `--help`, `--version`, richer diagnostics.
- [ ] **LSP** — syntax highlighting and basic diagnostics for editors.

---

## ⏸ Deferred

- [ ] **Tagged byte-buffer / string encoding** — heap strings are length-prefixed code units; revisit a unified byte buffer type.
- [ ] **Runtime-enforced fixed buffers** — `[N]T` is compile-time only; capacity traps / non-growing buffers later.
- [ ] **UTF-8 vs code-unit length** — clarify byte vs code-point policy for `len` / `[N]byte`.
- [ ] **`errdefer`** — error-path defer if/when needed.

---

## ❌ Removed / Not Planned

- `@while` loops: removed completely (use `@for` with a condition instead).
- C-style `@for ($i=0; i<N; i=i+1)`: not planned; use `@for (0..N) |i|`.
- **Generics / symbolic `[N]T` type params** — not planned; array lengths stay numeric literals only.
- **Tracing GC** — not planned; use allocators + `defer` instead.
