# LLTS Project Status & Roadmap

Zig implementation. The TypeScript prototype/reference is [`llts-js`](../llts-js).

## ✅ Current Capabilities

### Lexer (Scanner)

- [x] Basic Tokens: Identifiers, Numbers (int, float, hex, binary, octal), Strings, Booleans.
- [x] Registers: `$a`, `$t0`, etc. (declaration-only sigil; uses omit `$`).
- [x] Keywords: `return`, `true`, `false`, `break`, `continue`, `pub`, `defer`.
- [x] Compiler Directives: `@func`, `@import`, `@const`, `@if`, `@for`, `@struct`, `@typeOf`, `@sizeOf`, `@isError`, `@extern`.
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
- [x] `std/syscall`: raw `call` + typed POSIX wrappers (`read`/`write`/`open`/…) and host `SYS_*` / `O_*` constants.

### Tooling

- [x] `zig build` / `zig build test`.
- [x] Language conformance suite under `tests/*.test.ts` (Bun runner, Zig binary).
- [x] Runtime stack traces and source-context diagnostics on stderr.

---

## 🚧 Roadmap — Ordered by Priority

### P0 — VM hot path (CPU / memory)

Lean interpreter — efficient CPU, less memory, stay light/fast. No JIT.
Perf gate: `bun benchmarks/run.ts` (1M loop median).

- [x] **Fixed operand stack** — `STACK_MAX` buffer + `sp`; no `ArrayList.append` on push.
- [x] **Indexed globals** — `OP_GET_GLOBAL` / `OP_SET_GLOBAL` operand = `u16` slot; `.llb` v3 + `global_names[]`.
- [x] **Fused range `@for`** — `OP_FOR_PREP` + `OP_FOR_LOOP` for `start..end` captures.
- [x] **Int-specialized ops** — `OP_ADD_I64` / `OP_SUB_I64` / `OP_MUL_I64` / `OP_LT_I64` when both operands are int.
- [x] **Top-level as locals** — deferred: nested functions need free vars as globals; top-level stays **indexed global slots** (phase 2). Hot loops already use locals via `@for` / functions.
- [x] **Tighter dispatch** — `ip`/`sp` locals in `execute`; inline tiny stack/local handlers.

### P0 — Memory model (layout)

Value-slot heaps (`memory` / `immortal` as `ArrayList(Value)`) are a footgun for density and honest `@sizeOf`.
Widths (`u8`/`u16`/…) stay out until packed layout exists.

- [x] **Write RFC** — create [`docs/memory-model.md`](docs/memory-model.md) (does **not** exist yet; this checkbox *is* creating it).
- [x] **Packed heap region** — one byte bump (frame watermark + immortal/pass region policy).
- [ ] **Struct / array layout in bytes** — field offsets; `@sizeOf` = real byte size.
- [ ] **Unify slices** — strings, `[]byte`, value arrays → ptr+len into that region (strings + `[]byte` already share `vm.bytes`; value arrays still Value-slot).
- [ ] **Widths as real types** — `u8`/`u16`/… mean the same in source, typechecker, and runtime (not secret `i64`). **No** implicit promote/truncate; convert only via explicit cast (RFC: e.g. `@as(T, expr)`).

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
- [x] **`$name: T`**, `[]T` / `[N]T` (incl. nested), `T | error`, `?T` / `T | null`; aliases `i32`/`number`→`int`, `boolean`→`bool`.
- [x] **`string` ≡ `[]byte`**; string literals infer as `[N]byte`.
- [x] **Structs as types** — including imported `mod.Name` (e.g. `mem.Arena`).
- [x] **Debug type asserts**; strip with `--release`.
- [x] **`@typeOf(expr)`**
- [x] **`@sizeOf(T_or_expr)`** — static sizes for types / typed values; runtime `OP_SIZEOF` fallback (`tests/26_sizeof.test.ts`).
- [x] **`pub` for user files** — private decls stay in-module; relative `./` / `../` imports.

### P5 — Memory

- [x] **Arenas + allocators** — growable `Arena` (Zig-style chunks) + `defer`.
- [x] **`defer` / `errdefer`** — LIFO scope-exit cleanup; `errdefer` on error path only (`?` / error returns).
- [x] **No tracing GC** — ownership is explicit (allocator + defer).
- [x] **Frame regions** — VM rewinds heap bump on return; bare `Foo{}` / `[…]` are frame-local.
- [x] **Escape = compile error** — cannot return frame-local heap; use `@new(allocator, …)`.
- [x] **`@new`** — compiler intrinsic (Go `make`-style); Allocator comes from `std.mem`.

### P6 — Language (make the low-level story honest)

Forcing function: keep writing the self-hosted compiler. Whatever that parser cannot say cleanly is next.

#### Pointers vs values

- [ ] **`*T` / `?*T` as types** — `?Node` is a nullable heap handle pretending to be an optional struct. Linked lists and AST nodes need real pointers.
- [ ] **Address-of (`&x`)** — take a pointer to a local / field; distinguish value vs handle at the type level, not only by allocation region (`Foo{}` vs `@new`).
- [ ] **Real `@sizeOf` layout** — today `@sizeOf` is `field_count * 16` (VM slots). Sizes should reflect actual field layout once pointers exist.
- [ ] **Methods vs pointers** — `self` already mutates like a handle; document/enforce whether methods take `self: T` or `self: *T`.

#### Bytes and slices

- [ ] **One `[]T` model (ptr + len)** — unify interned strings, arena packed `@new(a, []byte, n)`, and value-slot arrays `[1, 2, 3]`. `string ≡ []byte` must be true at runtime, not only in the typechecker.
- [ ] **Slice syntax `arr[i..j]`** — language-level views; stop using `std/string.slice` as a stand-in.
- [ ] **Runtime-enforced `[N]T`** — fixed buffers with capacity traps; `[N]T` is compile-time only today.
- [ ] **UTF-8 vs byte length** — clarify `len` / `[N]byte` as bytes (not code points) once strings are `[]byte`.

#### Types that match the VM

- [ ] **`float` as a type** — VM and `std/math` already return floats; the typechecker does not know `float`.
- [ ] **Stop aliasing `i32` / `number` → `int`** — pick one integer width for the VM era; do not add `u16` / `i64` / packed structs until layout is real.

#### Abstraction without generics

- [ ] **Function types** — e.g. `$f: @func(int): int`. First-class functions exist; their types do not.
- [ ] **Nested / capturing functions** — nested `@func` is not supported; closures do not capture. Decide yes (with region rules) or no.
- [ ] **Allocator / Reader / Writer without generics** — either small interfaces/vtables, or stay concrete (`mem.Arena` + `[]T` only). Untyped native `std/list` / `std/map` should not remain a third language.

#### Tagged unions

- [ ] **Enum payloads** — `@enum Node { Literal(int), Binary(…), … }` (or equivalent). Enables AST nodes and typed errors without a generic `Node` bag of optional fields.
- [ ] **`@switch` exhaustiveness** — compile error when enum/union arms are missing and there is no `@else`.
- [ ] **Typed error sets (optional follow-on)** — once unions exist, `error` codes can be enums instead of strings.

### P7 — Tooling

- [ ] **Broader test coverage** — more Zig unit/integration cases for parser, compiler, and VM edge paths.
- [x] **Runtime stack traces** — LLTS call stacks on stderr with source context.
- [ ] **CLI improvements** — `--help`, `--version`, richer diagnostics.
- [ ] **LSP** — syntax highlighting and basic diagnostics for editors.
- [x] **Perf gate documented** — `bun benchmarks/run.ts` (1M loop median).

---

## ⏸ Deferred

- [x] **`errdefer`** — error-path defer; richer `error(code, payload)` with `.code` / `.message` / `.payload`.

---

## ❌ Removed / Not Planned

- `@while` loops: removed completely (use `@for` with a condition instead).
- C-style `@for ($i=0; i<N; i=i+1)`: not planned; use `@for (0..N) |i|`.
- **Generics / symbolic `[N]T` type params** — not planned; array lengths stay numeric literals only. Use interfaces or concrete `Arena` + `[]T` instead.
- **Tracing GC** — not planned; use allocators + `defer` instead.
- **More `@` directives / extra integer widths** — not until pointers, slices, and layout are real.
