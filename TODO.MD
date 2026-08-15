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

Packed byte heap + honest numeric widths. See [`docs/memory-model.md`](docs/memory-model.md).

- [x] **Write RFC** — [`docs/memory-model.md`](docs/memory-model.md).
- [x] **Packed heap region** — one byte bump (frame watermark + immortal/pass region policy).
- [x] **Unify slices** — strings, `[]byte`, structs, and **value arrays** share `vm.bytes` (`.slice` / `.bytes` / `.array`).
- [x] **Widths as real types** — full matrix `u1`/`i8`/`i16`/`i32`/`i64`, `u8`/`u16`/`u32`/`u64`, `f32`/`f64` honest end-to-end; aliases `int`/`number`→`i64`, `byte`→`u8`, `float`→`f64`, `bool`/`boolean`→`u1`; convert only via `@as` / `T(x)` sugar (integer literals may coerce into any integer width that fits; float literals are `f64` and may coerce into `f32`).
- [x] **`T(x)` cast sugar** — `u8(n)`, `ID(u)` ≡ `@as(T, x)` when `T` is a type and not a function (function names still call).

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
- [x] **`$name: T`**, `[]T` / `[N]T` (incl. nested), `T | error`, `?T` / `T | null`; numeric aliases `int`/`number`→`i64`, `byte`→`u8`, `float`→`f64`, `bool`/`boolean`→`u1`.
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

- [x] **`*T` / `?*T` as types** — pointer IR + parse; `@new` of a struct yields `*T`; field access auto-resolves through `*` / `?*`; `?Node` still works as optional struct (compat).
- [x] **Address-of (`&x`)** — `&struct_value` → `*T` (same packed handle; type-level). Rejects scalars, optionals, and already-`*T` (no `**T` / interiors yet).
- [x] **Packed `@sizeOf` layout** — struct/primitive sizes use real field layout (`src/compiler/layout.zig`); `@sizeOf(*T)` is handle-sized (8).
- [x] **Methods vs pointers** — unannotated method `self` defaults to `*T`; `self: T` / `self: *T` allowed; call sites auto-`&` / auto-deref receivers.

#### Bytes and slices

- [ ] **One `[]T` model (ptr + len)** — interned strings and arena packed `@new(a, []byte, n)` already share `vm.bytes`; value arrays are `.array` in the same heap. Remaining: unify slice headers end-to-end.
- [x] **Slice syntax `arr[i..j]`** — exclusive-end views on `[]byte` / `[N]byte` / string (`.bytes` / `.slice`); bounds-checked; not assignable.
- [x] **Open-ended slices `arr[i..]` / `arr[..j]`** — Zig-style; same for strings (`s[i..]`, `s[..j]`, `s[..]`); missing start → 0, missing end → len.
- [ ] **Compile-time bounds for constants** — when length and index/slice bounds are both known literals (string / `[N]T`), reject OOB at compile time. Runtime checks stay; no general const-eval.
- [ ] **Runtime-enforced `[N]T`** — fixed buffers with capacity traps; `[N]T` is compile-time only today.
- [ ] **UTF-8 vs byte length** — clarify `len` / `[N]byte` as bytes (not code points) once strings are `[]byte`.

#### Types that match the VM

- [x] **Numeric width matrix** — `u1`, `i8`…`i64`, `u8`…`u64`, `f32`/`f64`; aliases `int`/`number`→`i64`, `byte`→`u8`, `float`→`f64`, `bool`/`boolean`→`u1`; no implicit cross-width ops (use `@as`).

#### Abstraction without generics

- [x] **Function types** — e.g. `$f: @func(i64): i64`. First-class functions exist; their types do not. (Also listed under `@type` ship order.)
- [ ] **Nested / capturing functions** — nested `@func` is not supported; closures do not capture. Decide yes (with region rules) or no.
- [ ] **Allocator / Reader / Writer without generics** — either small interfaces/vtables, or stay concrete (`mem.Arena` + `[]T` only). Untyped native `std/list` / `std/map` should not remain a third language.

#### Tagged data (done — enums + struct unions)

- [x] **Tag-only `@enum`** — TS-style names → ints; no `Variant(T)` payloads.
- [x] **`@switch` exhaustiveness** — on enum / union `.kind`; value `@switch` may omit `@else` when exhaustive.
- [x] **Enum literal types `ExprKind.Literal`** — singleton field annotations; `@typeOf` prints `ExprKind.Literal`.
- [x] **Struct unions `A | B`** + **narrowing on `kind`** + **`@else` remaining-arm narrowing**.

#### `@type` — Go-style distinct names (not TS aliases)

`@type Name = T` declares a **new nominal type** with the same runtime layout as `T`. Distinct types with the same underlying representation are **not** assignable without `@as`. Transparent aliases are opt-in via `@alias`.

```llts
@type UUID = string;
@type ID = string;
$u: UUID = "…";
$i: ID = u;           # error
$i = @as(ID, u);      # ok
$i = ID(u);           # same — T(x) sugar

@alias Str = string;  # transparent — Str ≡ string
```

**What `@type` can declare** (RHS):

| Form | Example |
|------|---------|
| Named / width / existing | `@type UserId = i64` |
| Pointer / array / optional / error | `@type Path = [256]u8`, `@type Opt = ?Node` |
| Union (`\|`) | `@type Expr = Literal \| Add` — name `Expr` is nominal; arms still assign *into* `Expr` |
| Intersection (`&`) | `@type Rw = Readable & Writable` — **object shapes only**; merge fields (duplicate names must agree) |
| Tuple | `@type Pair = [i64, []byte]` — fixed anonymous product; access `.0` / `.1` (or unpack later) |
| Literals | `@type KindA = "a"`, `@type Z = 0`, `@type Lit = ExprKind.Literal` |
| Function type | `@type Handler = @func(i64): i64` |
| Object shape | `@type Counter = { value: i64; inc: @func(): i64 }` — name still nominal vs another identical shape |

**Not planned** (TS advanced / generics): mapped types, conditional types, `keyof`, `infer`.

**Rules:**

- Same wire layout as RHS; `@sizeOf(Name) == @sizeOf(RHS)`.
- `Name` ≰ `Name2` even when RHS equal — need `@as`.
- Underlying literals may coerce **into** an expected distinct type at annotated sites (`$u: UUID = "…"` ok); **named values** of another distinct type never coerce.
- `@typeOf` prints the distinct name (`UUID`), not `string`.
- `@struct` / `@enum` stay their own decls; `@type` names and composes them.
- `|` and `&` bind looser than `?` / `*`; `&` only on shape types (error if used on widths/unions/etc.).
- Tuples are distinct from arrays: `[i64, []byte]` ≠ `[2]any`; fixed length + heterogeneous elems.

**Ship order:**

- [x] **`@type Name = T` (distinct)** + **`@alias Name = T` (transparent)**
- [x] **Nominal assignability + `@as`** — UUID ≠ ID
- [x] **Literal types** — `"a"` / `0` / `true` / `Enum.Variant` as RHS; unions of literals
- [x] **Function types** — `@func(params): ret` as a type form
- [ ] **Object / shape types** — `{ fields; callables }` filled at init
- [ ] **Tuple types** — `[T, U, …]` values + field/index access
- [ ] **Shape intersection `&`** — merge object types; `Readable & Writable`
- [ ] **Optional sugar (later)** — `@enum Expr { Literal { … }, … }` → Kind + structs + `@type Expr = …`
- [ ] **Typed error sets (follow-on)**

Preferred tagged-data spelling with `@type`:

```llts
@enum ExprKind { Literal, Add }
@struct Literal { kind: ExprKind.Literal; value: i64; }
@struct Add { kind: ExprKind.Add; left: i64; right: i64; }
@type Expr = Literal | Add;

@type Readable = { read: @func([]byte): i64 };
@type Writable = { write: @func([]byte): i64 };
@type Rw = Readable & Writable;

@type Pair = [i64, []byte];

@func eval(e: Expr) { … }
```


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
- **More `@` directives** — not until pointers / remaining language surface needs them.
