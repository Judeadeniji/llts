# Native-stdlib plan (for the implementor agent)

Status: **approved, not started**. Phase 0 is the entry point.
Branch context: `feat/native-backend`, baseline commits `5852144` + `b7e56dc`
(perf: reachability-gated typecheck, ReleaseSafe `zig build release` step).

This document is the source of truth for scope. If you (the implementor) find
evidence that contradicts an assumption below, **record the finding in this
file and stop for confirmation** rather than silently widening scope.

---

## 0. Goal and locked decisions

**Goal:** as much of the standard library as possible written in LLTS itself,
with `extern` used only where LLTS cannot do the job, and a hard reduction of
the Zig `std` dependency in the runtime. Native is the future target; the
bytecode VM is a **reference oracle** for parity tests, not a compatibility
surface to preserve.

| Question | Decision (locked — do not relitigate) |
| --- | --- |
| Entry point | **Measure first** (Phase 0), before any std rewrite |
| Primitives | Pure LLTS where feasible; extern only for heap/frame, syscalls, clock, libm, process, TLS |
| Go ports (`std/log.lls`, `std/log/slog.lls`, `std/log/syslog.lls`, `std/slog.lls`, 47% of std) | **Deferred — untouched this pass** |
| Float formatting | **Keep the 17 `std.fmt` refs behind `formatFloat`** — the single documented exception to "no Zig std" |
| Syscall surface | **One typed dispatcher**: `@extern __syscall(nr, a, b, c, d, e, f): int` + LLTS wrappers/constants around it |
| `std/http` | **Both tiers, written in LLTS, this pass** — a C-like raw tier and a JS-shaped high tier; **synchronous** (the language has no async/promise/await) |
| Runtime (`src/runtime/`) | **Is not a VM.** Native typed Zig API. No `Value`, no `VMState`, no `NativeFunction` dispatch, no `ModuleObject`/`ListObject` |

### Why the syscall dispatcher

- One ABI entry to implement and port instead of ~60 named ones.
- `nr` is a literal at every LLTS call site, so in a native build LLVM folds
  the dispatch straight down to `@syscall` — no measurable overhead.
- Arity and types live in LLTS, where the rest of the type surface lives.
- Collapses `src/vm/builtins/syscall.zig` (680 lines, 74 `std.posix` refs) and
  most of `registry.zig` into a single runtime function.

---

## 1. Baseline facts (measured 2026-10-16; re-verify if you touch them)

### 1.1 The magic surface

- `src/compiler/scope.zig:79` — "`__` natives are provided by the runtime
  without an explicit listing": **any identifier starting with `__` is assumed
  to exist.** This is the loophole that must eventually close.
- **300 distinct `__*` symbols** are used by `std/`: **209 called as
  functions**, **91 used as constants** (OS flags: `__O_RDONLY`, `__SYS_*`,
  `__SIG*`, `__FD_*`, `__SEEK_*`, `__STD*_FILENO`…).
- Only **18** are seeded into `state.native_globals` (`src/compiler/state.zig:282-296`);
  **109** are named in `src/vm/builtins/registry.zig`; the rest pass through
  the `__` prefix rule.
- `@extern name;` already exists (`src/parser/decl.zig:65`, wired at
  `src/compiler/stmt/decl.zig:304`) but carries **no signature** and **std
  never uses it** (zero occurrences).

### 1.2 Strict-mode blockers

- Strict mode has **18 distinct `state.strict` check sites**, including three
  annotation rules at `src/compiler/typecheck/root.zig:961`, `:2478`,
  `:2765` ("must have an explicit type annotation in strict mode").
- Every `compileFail*` (`src/errors/compile.zig:34-55`) **aborts the whole
  compile** on the first error, so **nobody has ever seen the full blocker
  list.** That is the whole point of Phase 0.
- Known-by-scan: **198 untyped params + 3 untyped consts** in std —
  fs 70, slog 35, time 24, log 22, syslog 18, fmt 17, os 6, http 4, json 2.
  This is *only* the annotation rule; the other 15 rules are uncounted.
- `llts build --emit-zig examples/hello-world.lls` fails today on the first
  error (untyped param surfaced through `std/buffer.lls:86`).

### 1.3 std and the Zig-std dependency

- `std/`: 20 files, 3280 lines (2569 non-comment). `log`+`slog`+`syslog` = 1520
  lines = **47%**, all deferred.
- `std/*.lls` is thin shims: only 16% of lines touch a `__*` builtin directly.
  Examples: `std/json.lls` is 6 lines wrapping `__jsonParse`/`__jsonStringify`;
  `std/mem.lls` is 18 lines wrapping `__arena_*`.
- The real library is `src/vm/builtins/*.zig`: **6505 lines, 308 registered
  names.** Split:
  - **3782 lines / 12 files eligible for pure-LLTS rewrite** — fmt, string,
    json, list, map, buffer, log, io, print, print_ln, util, len
  - **2684 lines / 7 files that must stay host-backed** — mem (heap/arena),
    syscall, math (libm), time, os, http, registry
- Zig-std references inside those builtins:

  | `std.*` refs | where | replacement |
  | --- | --- | --- |
  | `std.posix` 108 (74 in `syscall.zig`) | syscalls | `__syscall` extern |
  | `std.ArrayList`/hashmaps 119 (fmt 45, string 43) | fmt, string | native `list`/`map` via the LLTS rewrite |
  | `std.json` 8 | `json_builtin.zig` | dies with the LLTS JSON parser |
  | `std.fs`/`std.process`/`std.os` ~30 | io, os | syscall externs |
  | `std.math` 53 | `math.zig` | libm externs |
  | **`std.fmt` 17 — all inside `formatFloat`** | `fmt.zig` | **KEEP (locked exception)** |
  | `std.http.Client` | `http.zig` | deleted — replaced by LLTS client over sockets |
  | `std.mem` 138 | everywhere | self-implement (trivial) or keep; zero cost either way |

### 1.4 The runtime must not become a VM

- `src/bytecode/value.zig:106` — `Value` is a `union(enum)` with `ptr: i32`
  into the Value-slot heap and `SpanRef`s into `VMState.bytes`.
- Builtins are written against `NativeFunction = fn(*anyopaque /*VMState*/, []Value)`
  (math refs `Value` 94×, string 43×, syscall 40×, fmt 39×).
- Therefore **"move the builtins into `src/runtime/`" is wrong.** See §3
  Phase 3. `docs/native-backend.md:186` currently says Phase 1 is "extract core
  types (`Value`, …) into `src/runtime/`" — **that bullet needs rewriting**
  (documentation fix, Phase 3).

### 1.5 Blast radius

- **688 std API call sites across 34 of 57 test files**; 20 std modules
  imported; 17 `docs/std/*.md`; 22 of 38 examples import std.
- Test usage ranking (imports / API refs): mem 94, buffer 27, string 21,
  math 21, index 17, fs 16, fmt 15, log 12, list 12, json 11, syscall 9,
  os 8, io 6, time 4, slog 4, map 4, http 4.
- `std/index.lls:8-9` imports `log.lls`, which pulls `slog` + `syslog` →
  **whole-program strict over `std/index` is blocked by the deferred Go
  ports.** See §4.
- Two tests hit the real network: `tests/18_http_json.test.ts:147`
  (`http://example.com`) and `:188` (`https://httpbingo.org/post`).

### 1.6 Findings appended during R1 (runtime, 2026-10-18)

- **VM div fast-path bug**: `src/vm/execute/root.zig:230` inlines
  `@divTrunc` without the `minInt / -1` guard → Debug VM **panics**
  (exit 134) where `binArith` would trap `"Integer overflow: division
  exceeds 'i64'"`. Native traps correctly; VM fast path should be fixed.
- **Nested-array clone**: VM `__cloneArray` shallow-shares inner handles
  (deep copy is the correct semantics). Native runtime deep-copies;
  do not carry the VM behaviour over.
- **Typed wrap normalisation**: VM `wrapToWidth` + read-back sign-extends
  signed widths / zero-extends unsigned ones. Native `arith.*Wrapped`
  returns the same normalised i64 (not raw truncated bits).
- **Concat is immortal**: VM `stringAdd` marks growth immortal
  (`noteImmortalGrowth`); native `mem.concat` allocates in the immortal
  buffer so results survive `leaveFrame`.
- **Trap reporting shape**: native `io.fail()` prints `Error: <msg>` and
  returns `error.RuntimeError` (like `runtimeFail`); emitted `main` exits 1.
  LLTS `defer` must be emitted as explicit return-path code, **not** Zig
  `defer`, so error unwinds never run it (VM parity).
- **print divergences fixed in native**: u64 above `maxInt(i64)` prints
  correctly unsigned (VM routes through `valueAsI64` and prints 0);
  untyped VM comparisons go through f64 and lose precision above 2^53
  (`compareOrd`/`asOrdFloat`) — native comparisons are exact.
- **Width table ownership**: canonical copy is now
  `src/runtime/widths.zig`; `src/compiler/widths.zig` re-exports it and
  keeps the `Value`-dependent helpers. `docs/native-backend.md` Phase 1
  bullet rewritten accordingly.
- **Registry drift since §1.1**: named entries 109 → 101,
  registered names 308 → 350; misroutes `__FD_CLOEXEC` (flag constant
  registered as native), `__copysign` (maps to wrong signature).
- **`@sizeOf(arr)`** is baked at typecheck as `count × 24` (Value size),
  not the native array size — native backend must recompute from layout.
- **`zig build test` toolchain hang** (Zig 0.15.2): the build runner's
  `--listen` test-server protocol deadlocks at teardown (runner in
  `futex_wait`, test binary idle on its command pipe). The test binaries
  pass standalone (`zig test tests/integration.zig`,
  `zig test tests/lsp_e2e.zig`, `zig test --dep llts -Mroot=src/lsp/tests.zig …`,
  `zig test --dep runtime -Mroot=src/runtime/tests.zig …`). Reproduces
  with any last step; not caused by runtime code. Re-check on Zig upgrades.

---

## 2. Extern budget (the contract to enforce)

Target: **~41 declared, typed externs** replacing 300 magic symbols.

| Bucket | ~Count | Mechanism |
| --- | --- | --- |
| OS/flag constants | **91** | plain LLTS `@const` — **no extern at all** |
| printf / string / json / buffer / list / map / io-path logic | ~120 calls | **pure LLTS** (deletes 3782 Zig lines) |
| syscalls | **1** | `@extern __syscall(nr: int, a: int, b: int, c: int, d: int, e: int, f: int): int` + LLTS wrappers |
| heap / frame / clone | ~12 | typed `@extern` (impossible in LLTS) |
| libm transcendentals | ~25 | typed `@extern` |
| process / clock / language | ~12 | typed `@extern` |
| TLS | 1 | typed `@extern` (crypto ⇒ meets "impossible") |
| float formatting | 17 refs | **kept as Zig `std.fmt`, behind `formatFloat`** |

Concretely, the extern surface after Phase 1 should be enumerable in a single
table (name, signature, which runtime function implements it, which std module
uses it). Build that table as part of Phase 0 step 3.

---

## 3. Phases

### Phase 0 — Measure (no std changes, no API changes)

**0.1 Collect-all strict diagnostics.**
Add a record-and-continue path alongside `compileFail*` in
`src/errors/compile.zig`: accumulate `{path, line, column, rule, message}` into
a new `state.strict_errors: std.ArrayList(StrictError)`.
Make the 18 `state.strict` sites plus the three annotation rules append and
continue instead of returning, **only when an opt-in flag is set**
(`CompilerState.strict_report_all`, default `false`, exposed as
`llts emit-zig --strict-report-all <file>`).
Default behaviour is unchanged → **all 730 tests must stay green.**
Rules that cannot continue safely (a site where the type is genuinely unknown
afterwards) may still bail; record that in a comment so the scorecard can say
"at least N".

**0.2 Scorecard.**
Run the flag over `std/index` and each std module individually. Produce:
rule × module × count, plus the first few locations per cell.
**Report `log`/`slog`/`syslog` as a separate "deferred" bucket** — they are
known-uncountable-this-pass but must be quantified so the §4 decision is
informed.

**0.3 ABI inventory.**
Scan `std/**/*.lls` for `__*`, cross-reference against
`src/vm/builtins/registry.zig` and the 18 seeds in `state.zig`. Classify every
symbol: `declared` / `prefix-loophole` / `unused`, and bucket it per §2
(constants → LLTS const, pure-LLTS candidate, must-be-extern).
Output: a table appended to this file (the Phase 1 worklist).

**0.4 Module ranking.**
Score each std module on lines × strict blockers × test usage →
keep / convert / kill order for Phase 2.

**Phase 0 acceptance:** four artifacts (scorecard, ABI inventory, ranking,
and the §4 checkpoint decision recorded in this file) + `zig build test` and
`bun run test` still green. **No std source edits.**

---

### Phase 1 — Extern budget enforcement

1. **Signature-carrying `@extern`.** Extend the parse rule at
   `src/parser/decl.zig:65` so `@extern name(a: int, b: string): int;` parses
   (currently only a name). Extend `Extern` in `src/ast/root.zig`, and at
   `src/compiler/stmt/decl.zig:304` register the *signature*, not just the
   name — calls to an extern become checkable, and an untyped extern param is
   a strict-mode error by construction.
2. **91 constants → LLTS `@const`.** In `std/syscall.lls`, `std/os.lls` etc.,
   replace `__O_RDONLY`-style references with plain LLTS constants holding the
   numeric values. Verify values against the VM builtin definitions (they are
   the oracle), not against memory.
3. **Collapse named syscalls.** Replace `__sys_*`-style externs with
   `@extern __syscall(nr, a, b, c, d, e, f): int` plus LLTS wrapper functions
   in `std/syscall.lls` so user-facing names (`syscall.open(...)`) do not
   change.
4. **Close the loophole.** Behind a flag first, remove the `__`-prefix
   acceptance at `src/compiler/scope.zig:79` and run 0.3's inventory as a test;
   once the list is fully declared, make undeclared host symbols a hard error.
5. **Gate:** new test asserting **every `__*` referenced in `std/` is declared
  ** (fails until step 4 lands — add it in step 4 alongside the flag flip).

**Phase 1 acceptance:** ABI test green, 730 green, `emit-zig` scorecard
strictly smaller than Phase 0's.

---

### Phase 2 — std rewritten in LLTS

Order (from 0.4; **json must land before http** — tier-2 `res.json()` needs it):

1. `fmt` — integers/strings only; **floats keep going to `formatFloat`**
2. `string`
3. `json` — own parser + stringifier in LLTS (deletes `std.json` usage)
4. `buffer`, `list`, `map`, `mem` inspection
5. `io` / `fs` — path and file logic in LLTS over syscall externs
6. `http` — both tiers, below

**Rules:**
- Each module lands **together with deletion of its Zig builtin** (fmt.zig
  shrinks but stays for `formatFloat`; string/json/list/map/buffer/io/print
  go away module-by-module).
- API-compatible where possible; where an API must change, update the 688 call
  sites and the matching `docs/std/*.md` in the same change.
- **`log`/`slog`/`syslog` are out of scope.** Do not annotate, move or "fix"
  them in this pass.
- Every `__*` touched must end up either deleted or in the §2 extern table.

**HTTP, two tiers, both LLTS, synchronous:**

- **Tier 1 (C-like):** socket/connect externs → LLTS
  ```
  http.dial(host, port) -> Conn
  conn.write(bytes) / conn.read(buf) / conn.close()
  ```
  Reuse existing primitives: `std/io.lls` already has `writeAll(fd, data)`,
  `read(fd, buf)`, `readLineFd(fd)`; `std/buffer.lls` has the byte buffer.
  Users assemble request bytes by hand.
- **Tier 2 (JS-like):**
  ```
  $res = http.fetch(url);                       // existing tests keep working
  $res = http.request(url, "POST", body);
  res.status / res.ok / res.headers / res.body
  res.text() / res.json()                        // methods returning string/value
  ```
  Built entirely on tier 1 + `buffer` + `string` + the LLTS JSON parser.
- **Error contract is fixed by tests** (`tests/18_http_json.test.ts:167-193`):
  `@isError(res)` is true with `err.code == "HttpError"` for `"not-a-url"`,
  `""` and `"://"`.
- **TLS:** `https` needs crypto ⇒ extern by the locked rule: one declared
  `@extern __tlsConnect(fd, host)` whose runtime implementation wraps a TLS
  stack. Do **not** write TLS in LLTS.
- Delete `__fetch` and `src/vm/builtins/http.zig`'s `std.http.Client` usage.
- No async: the language has no `async`/`await`/`promise`. Blocking only.

**Phase 2 acceptance:** all affected tests green (including
`tests/18_http_json.test.ts`), ABI test green, Zig-std references in the
deleted/rewritten modules at zero, `docs/std/*.md` updated.

---

### Phase 3 — Native runtime + emitter (interleaved; the perf driver)

The user's driver is **native performance**, and nothing in Phase 2 can be
*measured* without an emitter — so start the emitter right after Phase 0 and
interleave it with Phase 2 rather than leaving it last.

1. **Write `src/runtime/` as a native support library**, not a VM layer:
   - API takes/returns `i64`, `f64`, `[]u8`, pointers, small structs.
   - Owns: packed byte heap, arenas, frame watermarks, `__syscall`
     dispatch, libm passthrough, sockets/TLS, `formatFloat`.
   - **No `Value`, no `VMState`, no `NativeFunction`, no `ModuleObject`.**
   - **No Zig std** for `std.posix`, `std.fs`, `std.process`, `std.json`,
     `std.http`; keep `std.fmt` **only** for `formatFloat`; `std.mem`
     optional (self-implement the handful of helpers if cheap).
   - Nothing is *moved out of* `src/vm/builtins` — those stay as the VM
     oracle and are only re-based onto the runtime where a shared primitive
     is genuinely worth it (e.g. `formatFloat`).
   - Existing stubs at `src/runtime/{root,context,ops}.zig` (49 lines total)
     are placeholders to replace.
2. **Minimal emitter** (`src/compiler/codegen/emitter/`, currently a
   `return error.NotImplemented` stub): arithmetic, functions, returns,
   unboxed locals/params, frame `defer` watermark, top-level → `lls_main`,
   `pub fn main()`. Target: `examples/hello-world.lls` emits Zig that compiles
   under `zig build-exe`.
3. **Lower typed externs** from Phase 1 into runtime calls.
4. **Documentation fix:** rewrite `docs/native-backend.md:185-186` so Phase 1
   no longer lists `Value` as a runtime type, and states plainly that
   `src/runtime/` is not a VM and does not host value dispatch.
5. Then progress through the native-roadmap Phases 3-5 (structured control
   flow, heap ops, full `--native`, parity).

**Phase 3 acceptance:** `llts emit-zig examples/hello-world.lls` produces
compilable Zig; `zig build-exe` runs it; `docs/native-backend.md` corrected.

---

### Phase 4 — Parity (VM = oracle)

Same fixtures through both paths, diffed: stdout, stderr, exit code
(the verification pattern already written up in `docs/native-backend.md`).
Extend `tests/18_http_json.test.ts` coverage with a **local test server**
rather than adding more external-network tests.

New gates that must stay green from Phase 1 onward:
- **ABI test** — every `__*` in `std/` is declared.
- **Strict scorecard snapshot** — a fixed test file whose strict-error count
  must not regress.

---

## 4. Checkpoint decision (must be recorded in this file at end of Phase 0)

`std/index.lls:8-9` imports `log.lls` → `slog` + `syslog`, all deferred. So
whole-program `emit-zig std/index` **cannot** pass strict until one of:

- **(a)** annotate-only the logging modules (no structural change, no nuke) —
  cheapest unblock, keeps `index` honest;
- **(b)** make `index`'s logging import lazy/optional so non-logging programs
  are not charged for it;
- **(c)** accept per-module `emit-zig` instead of `std/index` for now.

Pick one with the scorecard in hand. Do not pick before Phase 0 step 2.

---

## 5. Verification commands

```bash
zig build && zig build test      # must exit 0 at every checkpoint
bun run test                     # 730 pass (ReleaseSafe path, ~5s)
bun run test:debug               # 730 pass (Debug path, ~75s)
./zig-out/bin/llts build --emit-zig --strict-report-all <file>   # Phase 0 scorecard
```

Baseline expectation at start: **730 pass / 0 fail.** Never land a phase with
fewer.

---

## 6. Risks and known unknowns

1. **Strict tail unknown** — the 198 annotations are *only* the annotation
   rule; the other 15 strict rules have never been counted. Phase 0 resolves
   this; if the number is very large, stop and re-plan scope.
2. **Go ports block `std/index`** under whole-program strict — §4 decision.
3. **VM slowdown** — moving logic from native Zig builtins into LLTS makes the
   interpreted VM slower. Accepted: the VM is the oracle, not the target.
4. **Two external-network tests** are the only coverage of the new HTTP tier;
   add a local server.
5. **Pure-LLTS fmt/json/string** need coverage beyond today's 688 call sites —
   add module-level tests as each rewrite lands, do not rely on the existing
   suite alone.
6. **Float formatting stays on `std.fmt`** — if a future requirement is
   "zero Zig std in the binary", that exception is the first thing to revisit.

## 7. Working agreements

- No commits unless explicitly asked (`HANDOFF.md`).
- Top-level `const` imports only, no inline `@import(...)` inside functions
  (`.agents/AGENTS.md`, enforced since `2b1d6ef`).
- Update the matching `docs/std/*.md` and `docs/architecture.md` in the same
  change as any std or build behaviour they describe.
- Append measured findings to §1 rather than editing numbers silently.
