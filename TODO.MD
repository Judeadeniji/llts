# LLTS Project Status & Roadmap

Zig implementation. The TypeScript prototype/reference is [`llts-js`](../llts-js).

## ✅ Current Capabilities

### Lexer (Scanner)

- [x] Basic Tokens: Identifiers, Numbers (int, float, hex, binary, octal), Strings, Booleans.
- [x] Registers: `$a`, `$t0`, etc. (declaration-only sigil; uses omit `$`).
- [x] Keywords: `return`, `true`, `false`, `break`, `continue`, `pub`, `defer`.
- [x] Compiler Directives: `@func`, `@import`, `@const`, `@if`, `@for`, `@struct`, `@typeOf`, `@sizeOf`, `@addrOf`, `@isError`, `@extern`.
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
- [x] `std/fmt`: Go-compatible formatted I/O (`printf`, `sprintf`, `println`, `errorf`, verbs `%v`, `%+v`, `%#v`, `%T`, `%t`, `%d`, `%b`, `%o`, `%x`, `%X`, `%c`, `%q`, `%f`, `%s`, `%p`).
- [x] `std/log`: Go-compatible leveled/prefixed standard logging (`Logger`, flags, `print`, `printf`, `println`, `fatal`, `panic`).
- [x] `std/slog`: Go-compatible structured logging (`LevelDebug`..`LevelError`, `debug`, `info`, `warn`, `err`, `with`, structured key-value attributes).
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

Packed byte heap + honest numeric widths.

- [x] **Write RFC** — memory model design finalized.
- [x] **Packed heap region** — one byte bump (frame watermark + immortal/pass region policy).
- [x] **Unify slices** — strings, `[]byte`, structs, and **value arrays** share `vm.bytes` (`.slice` / `.bytes` / `.array`).
- [x] **Widths as real types** — full matrix `u1`/`i8`/`i16`/`i32`/`i64`, `u8`/`u16`/`u32`/`u64`, `f32`/`f64` honest end-to-end; aliases `int`/`number`→`i64`, `byte`→`u8`, `float`→`f64`, `bool`/`boolean`→`u1`; convert only via `@as` / `T(x)` sugar (integer literals may coerce into any integer width that fits; float literals are `f64` and may coerce into `f32`).
- [x] **`T(x)` cast sugar** — `u8(n)`, `ID(u)` ≡ `@as(T, x)` when `T` is a type and not a function (function names still call).

### P0 — Silent Wrong Behaviour (no error, wrong result)

- [x] **Hex / binary / octal literals**
- [x] **`^` / `**` exponent**
- [x] **Unary `+`** — identity operator.
- [x] **`@const` holes** — const values are immutable end-to-end:
  - [x] `ORIGIN.x = 99` — rejected (`Cannot mutate field of constant`)
  - [x] **Mutating method call on const** — `ORIGIN.shift(5)` now errors `"Method might mutate constant 'ORIGIN'"` at both typecheck (`inferCall` after `resolveMethodCallee`) and emit (`emitMethodCall`). Allowed: `self: T` (caller clones via `__cloneBytes`), no `self` param (skippable — no receiver handle). Pointer-like `self` (unannotated or `*T`) on a const receiver is rejected. Tests: `tests/07_const.test.ts` (4 cases).
  - [x] **Const rebind shadows instead of erroring** — not a bug; shadowing a const binding with a new declaration is by design (warning only, asserted by `tests/07_const.test.ts`). Warning says `'{s}' shadows constant '{s}' declared at line {d}` at the hiding decl (no misleading `unused constant`); see `tests/40_unused.test.ts`. Assignment form (`ORIGIN = …`) errors correctly.
  - [x] **Aliasing hole** — fixed: aggregate value assignment/declaration emits `__cloneBytes` / `__cloneArray` when the RHS is a binding (`value_clone.cloneBuiltin` in `expr/assign.zig` + `stmt/decl.zig`), giving value semantics for structs, arrays, `[]byte`, and strings. Pointers (`*T` / `&x` / `?*T`) skip the clone and keep sharing. Covers declaration (`$a = ORIGIN`), plain assignment (`a = b`), field store (`box.val = other`), and static global assign. Compound ops (`+=`) unchanged. Method receivers unchanged (`self: T` clones, `self: *T` shares). Function args are still shared handles (pass `*T` explicitly to mutate caller's storage).
  - [x] **Const-ness through pointers / nested places** — `&ORIGIN` is rejected (`Cannot take the address of constant`); nested writes (`O.i.v = …`) and method calls on nested const places use `placeRoot` / `constPlaceRoot`.
  - [x] **Array / string `@const` writes** — `@const` globals and locals emit `__freeze` so packed storage traps on write (`Cannot mutate a constant`), including through parameters (`poke(A)`). Assigning `$r = A` now **copies**, so mutating `r` does not touch `A` (and does not need the freeze trap).
- [x] **Returning a param-derived local panicked the VM** — fixed in `9c283ae`: `$out: S = s; return out;` compiled but the caller's field read panicked heap-OOB (`readI64` past `vm.bytes`) because decl/assign recorded the local's `alloc_region` from the RHS while the emitted `__cloneBytes` / `__cloneArray` copy lives in the callee frame, so auto-clone-on-return never fired and the frame rewind freed the returned handle. The receiving local is now `.frame` whenever a clone was emitted: flat/nested value-struct copies auto-clone into immortal storage on return; slice/pointer-bearing copies get the honest escape compile error. Tests: `tests/16_escape_region.test.ts` (5 cases). Found 2026-10-26 while probing type-fn data structures.

### P0 — Compiler Authority (Native Emitter)

Rule: the native emitter lowers compiler facts and never re-derives them. See `.agents/AGENTS.md` §5.

- [x] **Make `ir.Type` the canonical type representation in typecheck** — the typechecker already converts AST type nodes to `ir.Type` and has structural `typeEquals`/`isSubtype`, but the authoritative stores are still display strings, so named/typedef/field/return types are round-tripped through `parseDisplayType`. Displays should be derived only for diagnostics/codegen output, never used as type identity.
  - [x] **1. Baseline tests** — add `tests/60_type_identity.test.ts` covering: `@type` vs `@alias`, typedef chains, module-qualified same-name types, generic instances, struct field types, and function return types. Run existing suite first. Native-only baseline: new test passes; the broader suite has pre-existing native-backend failures unrelated to this work.
  - [x] **2. Add compile-lifetime type arena** — add `type_arena: std.heap.ArenaAllocator` to `CompilerState` (`state.zig:190-230`), initialize/deinit it, and expose `state.typeAlloc()`. No behavior change.
  - [x] **3. Allocate typecheck IR in the state arena** — replace the local arena in `typecheck/root.zig:3209-3211` with `state.typeAlloc()`. Verify all `ta` users allocate there; run tests and check memory growth.
  - [x] **4. Dual-write expression types** — add `type_ir_of_results: AutoHashMap(*ast.Node, ir.Type)` to state; write the normalized IR in `recordExprType` (`typecheck/root.zig:1095-1110`) and `intrinsics.zig:129`. Keep the display write for now.
  - [x] **5. Dual-write type-value results** — add `type_call_ir_results`; write in `typecheck/root.zig:2211` and `intrinsics.zig:532`. Make `typeFromAst` `.call` (`from_ast.zig:100-104`) prefer the IR map, falling back to the display map.
  - [x] **6. Typedef IR** — add `TypeDef.ir: ?ir.Type`; populate in `stmt/decl.zig:454`, `typecheck/root.zig:3158`, and `generics.zig:155`. Make `resolveTypedef` (`from_ast.zig:314-344`) prefer `td.ir`; keep the display fallback. Test `33_typedef`.
  - [x] **7. Struct-field IR** — add `StructDef.field_irs: StringHashMapUnmanaged(ir.Type)`; populate where `def.types.put` happens (`typecheck/root.zig:3086`) and in layout registration. Make `fieldTypeFromStruct` (`typecheck/root.zig:699-703`) prefer IR. Test structs/shapes/layout.
  - [x] **8. Function-return IR** — add `FunctionDef.return_ir: ?ir.Type`; populate in `resolveSignatureTypes` (`typecheck/root.zig:3191`) and return refinement (`2784-2822`). Make `fnReturnType`, `inferCall`, and `flow.zig:500` prefer it. Test returns/error unions.
  - [x] **9. Global type IR** — add `global_type_irs: StringHashMap(ir.Type)`; dual-write at `typecheck/root.zig:2545,2560,2577,2587`, `stmt/decl.zig:150`, and `modules.zig:362,367` (no generics write site found). Prefer IR in `lookupModuleDeclExact`/`resolveModuleMemberType`; `typeFromAst` `.primary`/`.member` resolve named types, so global-value IR does not apply there. Test `14_modules`.
  - [x] **10. Remove display-based module detection in typecheck** — remove the redundant `from_ast.resolveType` module checks in member access and assignment; module objects are now detected from resolved IR (`ir.structNameOf` / the existing module branch). Test `14_modules`.
  - [x] **11. Replace sentinel display checks with IR predicates** — done (`dfd99ce`): `"*"`, `"unknown"`, `"null"`, `"unknown |"`, and `"never"` checks now use `ir` predicates.
  - [x] **12. Delete `parseDisplayType` from typecheck resolution paths** — done (`b9a507b`): `resolveTypedef`, `fieldTypeFromStruct`, `fnReturnType`, and `lookupModuleDeclExact` read IR; the parser remains only for literal type displays, anonymous shapes, and external/display-only inputs.
  - [x] **13. Make legacy display maps derived caches** — done (`f84f1df`): all display writes derive from IR at the same boundary; `verifyTypeCaches` (Debug) asserts each display equals `ownDisplay`/`ownDisplayQualified` of its IR, and `inferReturnTypeFromBody` now returns IR.
  - [x] **14. Migrate path/call consumers** — done (`157a8f0`): `expr/path.zig` and `expr/call.zig` read IR maps; parity 60 pass / 15 fail on `14_modules`, `52_type_functions`, `13_typecheck`, `50_type_values` (pre-existing native gaps).
  - [x] **15. Migrate binary/decl consumers** — done (`56f61bb`): `widthOf`, `isStringyNode`, `isByteElem`, and the declaration initializer display read IR first.
  - [x] **16. Migrate const/layout consumers** — done (`4746f79`): `fieldKindFromType`/`fieldKindForStruct` and `emitStructValue` project from `field_irs`.
  - [x] **17. Migrate escape/reachability consumers** — done (`7f0b38c`): deep-clone/nested-struct checks and method-target discovery read `field_irs`/`ir.structNameOf`; display path kept only for missing IR.
  - [x] **18. Final invariant test** — done (`9973535`): `verifyTypeCaches` now also rejects display-only records in `type_of_results`, `type_call_results`, and `StructDef.types`, and `60_type_identity` covers typedef + field + return identities. Focused suites (`60_type_identity`, `13_typecheck`, `14_modules`, `33_typedef`) run 53 pass / 19 fail with no invariant panic; the full suite was not run (requested to run only relevant tests).
- [x] **Persist typed nodes for codegen** — done (`valTypeFromIR`): typecheck already stores `ir.Type` per expression in `state.type_ir_of_results` (dual-written with the derived display cache, enforced by `verifyTypeCaches`), and the emitter now *consumes* it: `Emitter.valueType` reads `recordedType(node)` and projects a `ValType` straight from the IR (widths, bool, string/slice/array, pointer, struct, enum, optional, error union, `@type`-wrapped underlying) instead of re-deriving the type from a display string. Nodes the emitter still resolves through a recorded display (tuples, anonymous shapes, function values, plain unions) fall back to `classify` unchanged, so lowering behaviour is preserved. Remaining display parsing lives on annotation/param/field/global paths — the next item.
  - Verified 2026-11-09: `zig build` clean; VM-vs-native parity over hand-written programs (structs, nested structs + methods, pointers/`&`/pointer params, typedefs/aliases/shapes, error values, `.?`/`??`/`@if (x) |v|` optionals, string slicing, `[4]byte` arrays) unchanged from HEAD; `examples/` native build set identical apart from `enums.lls` now reaching a later lowering gap (`@nameOf`) instead of failing to resolve the enum type.
- [x] **Delete the emitter's type parser** — done (`396409f` + `valTypeFromIR`/`valTypeFor`): `classify`, `expandTypedefs`, `isErrorDisplay`, `childType`, `parseArrayShape`, `optionalPayloadDisplay`, `isConstByteSequenceDisplay`, and `displayForExpr` are gone. Every emitter type entry point (`valueType`, locals, params, globals, struct fields, assignment targets, range refinement, returns, captures) lowers the typecheck-recorded `ir.Type`, including anonymous shapes (projected through the registered shape layout) and optionals via `ir.optionalPayload`. Synthesized capture bindings (`@if (x) |v|`, loop/switch captures) now carry `ir_type` too. Missing or unrepresentable records produce the unsupported-type diagnostic with the recorded display, never a re-parse. Typecheck also types `.?` (`inferUnwrapExprType`).
- [x] **Use recorded expression types everywhere** — done: `valueType` is now a single `recordedType` → `valTypeFromIR` step. The `displayForExpr`/`classify` fallback and the `unwrap_expr` / `index` / `member` / devirtualized-`call` re-inference arms are deleted (the last removed dangling comment and NUL padding is gone too). The only remaining re-resolution is IR-only: a call recorded while its callee was still unrefined (mutual recursion) re-resolves through the callee's final `return_ir`. `root.zig`.
- [x] **Use the compiler's function return types** — done: `Emitter.functionReturnType` consumes `FunctionDef.return_type` (display) + `return_ir` only; `bodyHasValuedReturn`, `bodyReturnsOnlyErrors`, and `isPureErrorDisplay` are deleted from `unit.zig` along with the `"unknown | error"` body scan. Gradual `unknown | error` (functions whose body only returns `error(...)`) now projects to a bare error value in `valTypeFromIR`, so unannotated error-only functions (`paths.lls`) compile natively instead of failing with `does not support return type 'error'` — an improvement over the pre-refactor baseline. (Typecheck's own `bodyHasValuedReturn` remains: it is internal to return refinement.)
- [x] **Persist call/method resolution** — done: recorded `call node → target function key`, receiver mode, and generic instance during typecheck in `state.call_targets`. Native emitter directly consumes `call_targets` (for direct calls, generic calls, module calls, and method calls); deleted `resolveFunctionValue`, `functionReturnsFunction` return scanning, `resolveCallTargetKey`, and `methodTarget` re-resolution (and `methodSelfMode`). Module resolution is done at compile time.
- [x] **Use compiler mutation/read facts** — done: compiler records `read`, `assigned`, `reassigned`, and pointer-receiver mutation facts in `state.binding_facts`, `state.param_facts`, `state.for_capture_facts`, and `state.if_capture_facts` during analysis (`src/compiler/analyze/binding_facts.zig`). Native emitter directly consumes these facts to drive `var` vs `const` and `_ =` suppression; `prescan.zig`'s walks are deleted, and `stmtTerminates` is relocated to `stmt.zig`.
- [x] **Use compiler control-flow facts** — done: compiler records `terminates` on `CompilerState` during typecheck/analysis (`recordControlFlowFacts`). Native emitter directly consumes `self.state.terminates.get(node)`; deleted `stmtTerminates` from `stmt.zig`, `root.zig`, and `unit.zig`.
- [x] **Use compiler constant folding** — done: range evaluation and proven arithmetic facts moved to compiler analysis (`src/compiler/analyze/range.zig`) and recorded in `state.proven_arithmetic`. Emitter consumes `state.proven_arithmetic`, `state.size_of_results`, `state.name_of_plans`, `state.type_eq_folds`, and `state.type_call_results`; deleted `src/compiler/codegen/emitter/range.zig` and `Emitter.int_ranges`.
- [x] **Use compiler reachability** — done: computed once in `analyze`, stored on `state.reachability`, and shared with bytecode and native emission; emitter consumes `self.state.reachability`.
- [x] **Remove dead/duplicate intrinsic handling** — done: removed unreachable duplicate `@typeOf` branch in `emitCall` (`expr.zig`), routed `type_call_results` at call entry, and removed `staticTypeArgSize` fallback from `@sizeOf`.
- [x] **Enforce the contract in tests** — done: added contract unit tests in `tests/integration.zig` and `tests/57.4_compiler_authority.test.ts` asserting (a) explicit lowering failure diagnostics, (b) total absence of display-string type parsers, `range_mod`, and `prescan` in the emitter, and (c) deterministic emitted code across runs.

### Native Backend Lowering Gaps

Tracked lowering differences and remaining parity gaps between bytecode VM and native emitter:

- [x] **Runtime `@nameOf` on enums** — native emitter now lowers `.enum_type` plans to exhaustive tag→name switches (numeric enums) and `rt.arith.eqStr` chains (string enums), with a `""` fallback. Also fixed `prepareFunction` taking `&p` of a by-value param copy so `param_facts` actually matched (unused-parameter discards were emitted for read params). Tests: `tests/15_enums.test.ts` nameOf group (6 pass).
- [x] **Top-level global type propagation for computed expressions** — `seedGlobalValueTypes` infers unannotated/computed top-level globals before function bodies are checked and persists every resolved non-unit type in `state.global_types` / `global_type_irs`; module-alias bindings (`$lib = @import(...)`) are seeded from the import table so imported constants resolve. Also fixed a key-replacement leak in `range.zig` when module statements are visited twice. Tests: `tests/55_emit_zig.test.ts` value-producing `@if` and module parity.
- [ ] **General tagged unions and union return types** — discriminated struct unions (`Literal | Add`) and general union returns (`int | AppError`) fail with `native backend (Phase 2) does not support type 'Expr'` (`examples/tagged.lls`, `tests/55_emit_zig.test.ts`). Solution: compute union layouts (tag offset, variant sizes, alignment) in `layout.zig` and record union strategy facts in `CompilerState`; native emitter lowers them to Zig tagged unions.
- [ ] **Combined optional and error unions (`?T | error`)** — unions containing both `null` and `error` payloads return `null` in `valTypeFromIR` (`root.zig`). Solution: lower as Zig optional error unions `?!T` or tagged unions.
- [ ] **Tuples (`[T, U, ...]`)** — heterogeneous product types return `null` in `valTypeFromIR` (`root.zig`). Solution: add product layout calculation to `layout.zig` and record layout in `CompilerState`; lower as anonymous or compiler-generated Zig product structs (`struct { @"0": T, @"1": U }`).
- [x] **Anonymous shape values (`{ a: T, b: U }`)** — object literals and return shapes without nominal `@struct` names lower through layout-registered anonymous Zig struct types, and bare `{ … }` literals in `return` or nested fields type check directly against expected shapes/structs.
- [x] **Singleton literal types (`"hello"`, `0`, `true`)** — literal type singletons project to their underlying primitive types (`[]const u8`, `i64`, `bool`) in `valTypeFromIR` (`root.zig`) for runtime representation.
- [x] **Value-producing `@if` with captures** — `$x = @if (opt) |v| { break v; } @else { break 0; };` lowers to a labeled block capturing the optional payload before branching into value breaks.
- [ ] **Error-union captures in `@if`** — `@if (res) |val|` on `T | error` fails with `native backend does not support error-union @if captures yet` (`stmt.zig`). Solution: lower error check / unwrap before binding capture.
- [x] **Key capture facts by `*const ast.Node`** — `state.if_capture_facts` and `state.for_capture_facts` now key on `*const ast.Node` in `binding_facts.zig` and the emitter, preventing false "pointless discard of capture" errors.
- [ ] **`@switch` on non-primitives (strings, structured types)** — `@switch (s)` on string slices fails with `native backend (Phase 3) does not support @switch on '[]const u8' yet` (`stmt.zig`). Solution: lower string switch statements to `std.mem.eql` if-else chains or hash switches.
- [ ] **Rest / variadic parameters (`...rest: []T`)** — `@func fn(...rest: []int)` fails with `native backend does not support variadic functions yet` / `rest parameters yet` (`unit.zig`). Solution: emit Zig slice parameters `rest: []const T` and pack call-site arguments into stack arrays.
- [ ] **Materialization of first-class function values** — returning or passing function values at runtime fails with `native backend (Phase 2) does not support return type '@func(...)'` (`tests/55_emit_zig.test.ts`). Solution: typecheck establishes concrete machine function pointer types and linkage metadata in `CompilerState`; native emitter generates Zig function pointers (`*const fn(...) ...`) when devirtualization cannot resolve a single static target.
- [ ] **Standard library modules for native (`std/*`)** — deferred: no standard library in llts-zig for now. Examples importing `std/*` (23 of 39) require stdlib modules when designed.
- [ ] **Printing pointers and nested aggregates** — `print(&x)` or `print(nested_struct)` fails with `cannot print pointer type` / `cannot print aggregates containing structs yet` (`expr.zig`). Solution: expand runtime debug printing for pointers and nested struct fields.
- [ ] **Standalone library compilation mode** — compiling modules without `pub @func main()` fails with `native backend requires a pub @func main() entry point` (`examples/import_test_lib.lls`). Solution: support library/module emission mode in `emit-zig`.

### Documentation Gaps

Discrepancies where current documentation in `docs/` differs from compiler capabilities or misses recent additions:

#### Backend Parity & Limitations Discrepancies
- [ ] **First-class function values** — `docs/functional-and-pipes.md` documents storing `@func` in variables, callbacks, and structs/shapes with "direct indirect-call machine dispatch", but native backend only supports statically resolved direct calls. Document the current native limitation.
- [ ] **String `@switch` prongs** — `docs/control-flow.md` gives an example of `@switch (role)` matching string literals (`"admin"`), but native compilation rejects string prongs with `native backend (Phase 3) does not support @switch on '[]const u8' yet`. Clarify VM-only status or native gap.
- [ ] **Variadic / rest parameters** — `docs/functions.md` documents `@func sum(...args): i64`, but native backend rejects variadics (`native backend does not support variadic functions yet` / `rest parameters yet`). Note backend status.
- [ ] **Heterogeneous tuples** — `docs/sequences.md` documents tuples (`[i64, string]`, `pair.0`, `record.0 = 10`), but tuples are not yet lowered in the native backend (`valTypeFromIR` returns `null`). Document native status.
- [ ] **`@nameOf` on runtime enums** — `docs/intrinsics.md` summary table lists `@nameOf` as fully supported across VM & Native, but runtime enum values currently fail natively with `native backend cannot lower runtime @nameOf on enums yet`. Note enum runtime limitation.
- [ ] **Union return types & general unions** — `docs/types/algebraic-types.md` documents arbitrary unions (`i64 | string`, `i64 | ParseError` return), but native backend rejects non-optional/non-bare-error unions. Clarify native backend support boundary.
- [ ] **Value-producing `@if` with captures** — `docs/control-flow.md` documents value `@if` and optional captures, but combining them (`$x = @if (opt) |v| { break v; } @else { break 0; };`) is rejected natively with `native backend does not support @if captures yet`.
- [ ] **Backend compatibility matrix** — `docs/tooling-and-cli.md` and `docs/getting-started.md` mention `--native` but lack a feature compatibility matrix distinguishing VM-supported vs native-ready features.

#### Undocumented Compiler Features
- [ ] **Value parameters on type functions** — type functions can take integer value parameters evaluated at compile time (`@func Pick(T: type, n: i64): type { @if (n == 1) { return T; } return ?T; }`). Missing from `docs/metaprogramming.md`.
- [ ] **Type argument inference on generic functions** — generic functions infer type arguments from value parameters (`max(3, 9)` infers `T = i64`). Missing from `docs/metaprogramming.md` and `docs/functions.md`.
- [ ] **Compound `@if` condition folding in type functions** — type-function `@if` folds `!`, `&&`, `||`, and comparisons (`<`, `<=`, `>`, `>=`, `==`, `!=`) over types and compile-time integers. Missing from `docs/metaprogramming.md`.
- [ ] **Anonymous struct initialization from type-function shapes** — object literals can initialize shape types returned from type functions (`$x: Make(i64) = { a: 1 };`). Missing from `docs/types/user-defined.md` and `docs/metaprogramming.md`.

#### Standard Library Clarification
- [ ] **Document stdlib status** — clarify across `docs/` that `llts-zig` currently does not provide a standard library (`std/*`); standard library implementations will be provided as an optional external library in a future phase.

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
- [x] **`const` literal modifier** — `const "x"` / `@const $k = "x"` keep singleton type `"x"` (and deep tuples for `const […]`); bare `"x"` still `[N]byte`.
- [x] **Structs as types** — including imported `mod.Name` (e.g. `mem.Arena`).
- [x] **Debug type asserts**; strip with `--release`.
- [x] **`@typeOf(expr)`** — returns a compile-time `type` value; operand never evaluated.
- [x] **`@sizeOf(T_or_expr)`** — static sizes for types / typed values; runtime `OP_SIZEOF` fallback (`tests/26_sizeof.test.ts`).
- [x] **Types as compile-time values** — meta type `type`; `@typeOf(...)` usable anywhere a type is (annotations, params, returns, struct fields, `@alias`, composites, `@as`, `@new`, `@sizeOf`); type `==`/`!=` folded at compile time; type values rejected in runtime slots (`tests/50_type_values.test.ts`).
- [x] **User-defined type functions and generics** — `@func Opt(T: type): type { return ?T; }` evaluated at compile time; `@func max(T: type, a: T, b: T): T` monomorphized per type argument (`src/compiler/generics.zig`, `tests/52_type_functions.test.ts`). Gaps tracked below.
- [ ] **Type functions / generics follow-ups** — gaps verified 2026-10-26:
  - [x] **Type params on struct methods** — `@func get(self: Box, T: type): T { … }` inside `@struct Box` is a method template registered as `Box::get`; `box.get(i64)` instantiates it (type args explicit or inferred from the arguments, value params work too) and the receiver is passed implicitly. `GenericCall.receiver` tells the emitter to prepend the receiver instead of re-deriving the split from the template.
  - [x] **Value params on type functions** — `@func Pick(T: type, n: i64): type { @if (n == 1) { return T; } return ?T; }`; value args must be compile-time integers (literal, negated literal, `true`/`false`) and take part in the memo key, so `Pick(i64, 1)` and `Pick(i64, 2)` get distinct instances (`generics.isValueParam`, `TypeFnEval`).
  - [x] **Anonymous structs** — nameless shape types are structural: a type fn may return `{ a: T }`, `$x: Make(i64) = { a: 1 }` initializes it (typecheck resolves the annotation's type fn when the object literal is checked; codegen keys the layout by the shape display), and values interchange with an inline `{ a: i64; }` annotation at call sites (`TODO`: `Named { … }` / `@type Named = …` still work too).
  - [x] **Local `@alias` from a type function** — `@alias L = Opt(i64)` inside a function body resolved to `unknown` because local types are hoisted before typecheck; the RHS is now resolved on the declaration statement, where the env is live (`resolveLocalTypeDecl`).
  - [x] **Type-fn `@if` beyond a single type compare** — conditions fold through `!`, `&&`, `||` and multiple type `==` / `!=` comparisons (`evalTypeCond`). Value conditions (`@if (N == 1)`) come with value params below.
  - [x] **Type-argument inference** — `max(3, 9)` binds `T` from the value arguments' types (`inferTypeArgsFromValues`); explicit `max(i64, 3, 9)` still works, and an unfixable param reports "Cannot infer type argument 'T' … pass it explicitly". Call sites record `GenericCall.value_args`, so codegen drops the leading type arguments instead of re-deriving the split.
  - [x] **Generic struct / enum declarations** — `@struct Name(T: type) { … }` parses and registers as a template (`struct_templates`), never laid out or emitted itself; each distinct argument list instantiates one entry of `structs` with fields substituted and methods registered as `Name(T)::method` (`generics.registerStructTemplate` / `instantiateStruct`). `Name(T)` works in every type position and `Name(T) { … }` is a literal form; instances nest, may be self-referential through a pointer and queue their methods for typecheck like generic functions. `@enum` rejects parameters (variants carry no types). Integer value parameters on structs substitute into array lengths only (`@struct Buffer(T: type, N: i64) { items: [N]T; }`), so `Buffer(u8, 4)` and `Buffer(u8, 8)` are distinct instances (`local_types.substituteLengths` rewrites `[N]T` length text in the cloned body). Instance methods are queued lazily (`state.instance_methods` + `noteInstanceMethodUse`) and only typechecked once called; the ones nothing calls are dropped from `state.functions` before reachability (`generics.dropUnusedInstanceMethods`), so a bare method name in the call index cannot pull an untypechecked body into the emit set.
- [x] **Local `@type` / `@alias` inside blocks** — lexically block-scoped (nested blocks, `@comptime`, block expressions, top-level blocks; shadowing allowed); hoisted under a `<fn>[::<n>]::Name` key (`src/compiler/local_types.zig`, `tests/51_local_types.test.ts`).
- [x] **`@nameOf(enum_or_error)`** — variant/member spelling as declared (`tests/15_enums.test.ts`, `tests/37_error_sets.test.ts`).
- [x] **`pub` for user files** — private decls stay in-module; relative `./` / `../` imports.

### P5 — Memory

- [x] **VM arenas + allocators (legacy)** — growable `Arena` (Zig-style chunks) + `defer`.
- [x] **`defer` / `errdefer`** — LIFO scope-exit cleanup; `errdefer` on error path only (`?` / error returns).
- [x] **No tracing GC** — ownership is explicit (allocator + defer).
- [x] **Frame regions** — VM rewinds heap bump on return; bare `Foo{}` / `[…]` are frame-local.
- [x] **Escape = compile error** — cannot return frame-local heap (except flat scalar structs, which auto-clone into immortal storage on return).
- [x] **Remove native `@new`** — native compilation rejects the intrinsic instead of ignoring its allocator and placing every result in immortal storage. The bytecode compiler retains it temporarily for VM compatibility.
- [ ] **Move allocation to the standard library** — after generic struct methods (or an equivalent type-parameterized library mechanism) and raw typed-memory construction exist, provide allocator implementations as ordinary library code. The compiler must not require an `alloc`/`resize`/`free` method set, a fixed arena representation, or a total capacity known in advance. Libraries choose their own API, chunking/growth strategy, lifecycle, and failure type.
- [ ] **Remove legacy VM `@new`** — migrate bytecode users to the standard-library allocation API, then delete the intrinsic and `__arena_alloc*` compiler/runtime coupling.

### P6 — Language (make the low-level story honest)

Forcing function: keep writing the self-hosted compiler. Whatever that parser cannot say cleanly is next.

#### Pointers vs values

- [x] **`*T` / `?*T` as types** — pointer IR + parse; field/index access auto-resolves through `*` / `?*`; `?Node` still works as optional struct (compat). The legacy VM `@new` yields `*T` for structs and arrays.
- [x] **Address-of (`&x`)** — `&aggregate` → `*T` for structs, arrays (`[N]T` / `[]T` / `[]byte`), tuples, shapes (same packed handle; type-level). Indexing auto-derefs `*T` / `?*T`. Rejects scalars, optionals, and already-`*T` (no `**T` / interiors / stack scalars yet).
- [x] **`@addrOf(x)`** — packed-heap identity as `i64` (offset); equal for aliases, diverges after value copy. Exhaustive suite: structs/arrays/`[]byte`/tuples/shapes/`@new`/`@const`/`*T` params; rejects scalars/enums/optionals (`tests/53_addr_of.test.ts`, 37).
- [x] **`void` / `null` / `never`** — distinct roles: `void` = unit (no result), `null` = optional absence only, `never` = noreturn/bottom. `Value.void` + `OP_VOID`; reject `: null` returns and `void`/`never` in unions. Exhaustive: `tests/54.1_void`, `54.2_null`, `54.3_never`.
- [x] **Packed `@sizeOf` layout** — struct/primitive sizes use real field layout (`src/compiler/layout.zig`); `@sizeOf(*T)` is handle-sized (8).
- [x] **Methods vs pointers** — unannotated method `self` defaults to `*T`; `self: T` / `self: *T` allowed; call sites auto-`&` / auto-deref receivers.

#### Bytes and slices

- [ ] **One `[]T` model (ptr + len)** — interned strings and arena packed `@new(a, []byte, n)` already share `vm.bytes`; value arrays are `.array` in the same heap. Remaining: unify slice headers end-to-end.
- [x] **Slice syntax `arr[i..j]`** — exclusive-end views on `[]byte` / `[N]byte` / string (`.bytes` / `.slice`); bounds-checked; not assignable.
- [x] **Open-ended slices `arr[i..]` / `arr[..j]`** — Zig-style; same for strings (`s[i..]`, `s[..j]`, `s[..]`); missing start → 0, missing end → len.
- [ ] **Compile-time bounds for constants** — when length and index/slice bounds are both known literals (string / `[N]T`), reject OOB at compile time. Runtime checks stay; no general const-eval.
- [ ] **Runtime-enforced `[N]T`** — fixed buffers with capacity traps; `[N]T` is compile-time only today.
- [ ] **UTF-8 vs byte length** — clarify `len` / `[N]byte` as bytes (not code points) once strings are `[]byte`.
- [x] **String comparison boundary** — `==` / `!=` compare byte content in the core language; ordered comparisons (`<`, `<=`, `>`, `>=`) are rejected. Ordering policy belongs in the standard library.

#### Types that match the VM

- [x] **Numeric width matrix** — `u1`, `i8`…`i64`, `u8`…`u64`, `f32`/`f64`; aliases `int`/`number`→`i64`, `byte`→`u8`, `float`→`f64`, `bool`/`boolean`→`u1`; no implicit cross-width ops (use `@as`).

#### Abstraction without generics

- [x] **Function types** — e.g. `$f: @func(i64): i64`. First-class functions exist; their types do not. (Also listed under `@type` ship order.)
- [ ] **Nested / capturing functions** — nested `@func` is not supported; closures do not capture. Decide yes (with region rules) or no.
- [ ] **Allocator / Reader / Writer without generics** — either small interfaces/vtables, or stay concrete (`mem.Arena` + `[]T` only).
- [x] **`std/list` / `std/map` / `std/buffer` arena-backed** — require `Arena` (or immortal escape hatch); element storage in arena bump; free via `reset`/`deinit`.

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
- [x] **Object / shape types** — `{ fields; callables }` filled at init
- [x] **Tuple types** — `[T, U, …]` values + field/index access
- [x] **Shape intersection `&`** — merge object types; `Readable & Writable`
- [ ] **Optional sugar (later)** — `@enum Expr { Literal { … }, … }` → Kind + structs + `@type Expr = …`
- [x] **Typed error sets** — `@error Name { A, B }`, `|` / `&`, exhaustive `@switch`, `?` through composition

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
- [x] **CLI improvements** — `--help`, `--version`, richer diagnostics.
- [ ] **LSP** — syntax highlighting and basic diagnostics for editors.
- [x] **Perf gate documented** — `bun benchmarks/run.ts` (1M loop median).

---

## ⏸ Deferred

- [x] **`errdefer`** — error-path defer with code-only `error(code)` values (`.code` / `.message`); use a wrapper value for extra data.

---

## ❌ Removed / Not Planned

- `@while` loops: removed completely (use `@for` with a condition instead).
- C-style `@for ($i=0; i<N; i=i+1)`: not planned; use `@for (0..N) |i|`.
- **Symbolic `[N]T` length params** — not planned; array lengths stay numeric literals only. Type parameters (`T: type`) are supported; see type functions above.
- **Tracing GC** — not planned; use allocators + `defer` instead.
- **More `@` directives** — not until pointers / remaining language surface needs them.
