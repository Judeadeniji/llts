# LLTS Flexibility-Hole Audit & Closure Plan

> **Principle:** No hole for flexibility. Every escape hatch, silent fallback,
> and gradual-mode leak is a bug waiting to happen. If the type system can't
> prove it, the compiler must reject it — not defer it to runtime.

**Audit date:** 2026-10-27
**Method:** Full sweep of `typecheck/`, `expr/`, `stmt/`, `layout.zig`,
`widths.zig`, `intrinsics.zig`, `value_clone.zig`, and `vm/execute/`.
Cross-checked against `docs/soundness-roadmap.md`.

**Result:** 5 critical, 17 moderate, 7 minor holes. Several invariants the
roadmap marks `[x]` are only enforced under `--strict`, which is **not** the
default for `run`/`build`/`dump`.

---

## Tier 1 — Critical (any bug can slip through)

### C1 — `unknown` is a universal subtype in gradual mode
**Location:** `src/compiler/typecheck/ir.zig:616,619`, `src/compiler/typecheck/root.zig:239`
**Problem:** `a == .unknown → true`, `b == .unknown → true`. Non-short-circuit:
`if (!state.strict and involvesUnknown(got) or involvesUnknown(expected)) return;`
skips validation entirely. Any unknown-typed expression flows into any typed slot.
**Fix:** Seal `unknown` in all modes. `unknown` never reaches codegen. Annotate
or error. This is the root cause of most moderate holes.

### C2 — `@as` downcasts unions with no tag check; integer narrowing unchecked
**Location:** `src/compiler/intrinsics.zig:652,655`
**Problem:** `@as(u8, 100000)` compiles (runtime abort only). Union downcast
(`Literal | Add` → `Literal`) compiles to a no-op — no tag check, wrong layout read.
**Fix:** Compile-time range check for integer casts. Runtime tag check for union
downcasts (emit a `switch` or trap).

### C3 — `OP_ASSERT_TYPE` is a no-op in the VM
**Location:** `src/vm/execute/root.zig:721-723`
**Problem:** Operand read and discarded. Also only emitted in debug builds
(`src/compiler/stmt/decl.zig:102-111`). Second line of defense provides zero protection.
**Fix:** Implement as a real tag check, or delete it. Prefer implement.

### C4 — Unhandled AST expr kinds emit no bytecode silently
**Location:** `src/compiler/expr/root.zig:40`
**Problem:** `else => {}` — silent stack corruption instead of compile error.
**Fix:** `else => return compileFail(...)`.

### C5 — Raw `i64` assignable to any enum
**Location:** `src/compiler/typecheck/ir.zig:695-701`, `src/compiler/stmt/decl.zig:173-174,180`
**Problem:** `.enum_` with got `.i64` → `isSubtype` returns true. Invalid discriminants
enter `@switch` prong comparisons.
**Fix:** Require `@as(EnumType, n)` or `Enum.Variant` literal. Raw int → enum is
a compile error.

---

## Tier 2 — Moderate (looseness that causes real bugs)

### M1 — Exhaustive-return only checked in `--strict`
**Location:** `src/compiler/typecheck/root.zig:2625-2645`
**Problem:** Non-void function that falls through silently returns void in gradual mode.
**Fix:** Lift the gate. Compile error in all modes.

### M2 — Truthiness `@if(i64)` allowed in gradual mode
**Location:** `src/compiler/typecheck/root.zig:1568-1573`
**Problem:** JS-style truthiness bugs (`0`, `""`, empty arrays).
**Fix:** Lift the gate. `@if` condition must be `bool`/`u1`.

### M3 — `@if (x) |v|` on non-container binds whole value
**Location:** `src/compiler/typecheck/root.zig:1561-1566`
**Problem:** Capture semantics silently change meaning between modes.
**Fix:** Error if capture target is not `?T` or slice/array.

### M4 — Member access on non-struct falls back to dynamic `OP_GET_PROPERTY`
**Location:** `src/compiler/typecheck/root.zig:1325`, `src/compiler/expr/aggregate.zig:464-468`
**Problem:** "property does not exist" becomes a runtime failure. Dynamic load
bypasses the static field table.
**Fix:** Error. No dynamic property loads.

### M5 — `typesAssignable` substring-matches `"unknown"`
**Location:** `src/compiler/stmt/decl.zig:170-171`
**Problem:** Type literally named `xunknownx` matches. String test, not type relation.
**Fix:** Exact match, or use the type-IR relation.

### M6 — Unannotated struct fields silently default to `int`/`i64`
**Location:** `src/compiler/stmt/decl.zig:320`, `src/compiler/layout.zig:102-127`
**Problem:** Wrong layout width with no diagnostic.
**Fix:** Require annotation. No default.

### M7 — `sizeOfTypeName` returns 8 for unknown names
**Location:** `src/compiler/layout.zig:42-55,86,207`
**Problem:** Unknown types silently get 8-byte layout. Size mismatches propagate.
**Fix:** Hard error.

### M8 — `??` and `|>` produce `TUnknown` with no compatibility check
**Location:** `src/compiler/typecheck/root.zig:1174-1175`
**Problem:** Type mismatch between fallback and optional payload passes silently.
**Fix:** Type-check LHS/RHS compatibility.

### M9 — Mixed-width comparisons only warn; `<=`/`>`/`%` untyped
**Location:** `src/compiler/expr/binary.zig:110-118,174`
**Problem:** Mixed-width `<` compares with wrong width. Signedness bugs compile with warning.
**Fix:** Enforce same-width or explicit `@as`.

### M10 — Clone-on-assign misses `.call` / `.index` returns
**Location:** `src/compiler/value_clone.zig:13-29`
**Problem:** Value-semantics bypass: mutating copy mutates source / callee frame.
**Fix:** Extend `cloneBuiltin` to cover call/index results of aggregate type.

### M11 — Unreachable functions not typechecked in gradual mode
**Location:** `src/compiler/typecheck/root.zig:2995`, `src/compiler/root.zig:50`
**Problem:** Dead-by-reachability code can contain type errors.
**Fix:** Always typecheck all declared functions.

### M12 — `@switch` exhaustiveness silently skipped when scrutinee unresolvable
**Location:** `src/compiler/stmt/control.zig:160,184-185,497-498`
**Problem:** Typo'd scrutinee disables exhaustiveness guarantee with no diagnostic.
**Fix:** Error if scrutinee type can't be resolved.

### M13 — `@for` over unknown → capture is unknown
**Location:** `src/compiler/typecheck/root.zig:1644-1645`
**Problem:** Loop-carried values leak `unknown` into the body.
**Fix:** Error.

### M14 — Type resolution degrades to `TUnknown` on missing types
**Location:** `src/compiler/typecheck/from_ast.zig:25,336-339,1150`,
`src/compiler/stmt/decl.zig:264,268,322,477`
**Problem:** Arrays/structs of unknown element type defeat bounds/layout checking.
**Fix:** Error.

### M15 — Flow analysis best-effort, no facts on unknown
**Location:** `src/compiler/typecheck/flow.zig:143-144,443,452,460`
**Problem:** Narrowing silently doesn't happen. Self-heals once C1 seals unknown.
**Fix:** Depends on C1. After C1, verify narrowing works for all typed paths.

### M16 — Pointer indexing `p[i]` is unchecked
**Location:** `src/vm/execute/heap.zig:126`
**Problem:** Raw unchecked memory arithmetic on `*T`.
**Fix:** Fat `*T` with length, or ban indexing on bare `*T`.

### M17 — `print` skips arg type checking
**Location:** `src/compiler/expr/call.zig:20-26`
**Problem:** Intentional static-check bypass.
**Fix:** Check args are printable (string/number/bool/error).

---

## Tier 3 — Minor (data loss with only a warning)

### m1 — f64→f32 silent precision loss
**Location:** `src/compiler/typecheck/root.zig:314,323,347-399`
**Fix:** Error in all modes, or require `@as`.

### m2 — `unknown` leaks through intrinsic paths
**Location:** `src/compiler/typecheck/root.zig:1013`,
`src/compiler/intrinsics.zig:648,108,245,445,523`
**Fix:** Sealed by C1.

### m3 — `@intFromFloat` truncation; `@as` range errors only at runtime
**Location:** `src/compiler/widths.zig:31-36,65-66`, `src/vm/execute/root.zig:764-781`
**Fix:** Compile-time check if literal; runtime trap otherwise.

### m4 — Escape analysis returns `.unknown` for unrecognized shapes (counts as pass)
**Location:** `src/compiler/escape.zig:31,155-169`
**Fix:** After C1, unknown shapes should be errors, not silent passes.

### m5 — Discriminant narrowing only works on bare identifiers
**Location:** `src/compiler/stmt/control.zig:349-361`
**Fix:** Extend to member chains.

### m6 — `OP_SIZEOF(.ptr) => 4` but addresses are i64
**Location:** `src/vm/execute/root.zig:734`
**Fix:** Fix to 8.

### m7 — Gradual field access on error unions / non-constant indices
**Location:** `src/compiler/typecheck/root.zig:1300,1366`
**Fix:** Sealed by C1/C4.

---

## Execution Order

| Step | Holes | Rationale |
|------|-------|-----------|
| 1 | C4 | Trivial; catches silent stack corruption |
| 2 | C1 | Seal `unknown` — root cause of most moderate holes |
| 3 | M5, M6, M7, M14 | Type resolution hardening (no silent fallbacks) |
| 4 | C5, M9, m1 | Numeric/enum strictness |
| 5 | C2, C3 | Runtime assertions + cast checks |
| 6 | M1, M2, M3, M4, M11, M12, M13, M17 | Lift strict gates, close gradual-mode leaks |
| 7 | M8, M10, M15, m5 | Inference / clone / narrowing fixes |
| 8 | M16, m3, m6, m4 | Pointer/size/float edge cases |

**Per step:** fix → rebuild → full suite green → commit.

---

## Relationship to `soundness-roadmap.md`

The roadmap marks many invariants `[x]`, but the checkmarks are **strict-mode-gated**.
This audit found the gates are the holes. This plan lifts the gates so the
invariants hold in **all** modes. Once complete, update the roadmap to remove
the strict-mode qualifiers.
