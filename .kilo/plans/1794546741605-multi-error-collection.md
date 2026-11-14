# Multi-Error Collection Across the Native Pipeline

## Goal

Make `llts` collect and report multiple independent errors before exiting, instead of stopping at the first one, for the native pipeline:

- scanner (lexical recovery)
- parser (statement/block recovery)
- typechecker / `compiler.analyze` (statement and expression recovery)
- native emitter (`llts emit-zig`, `llts run --native`, `llts build --native`)

Bytecode/VM lowering is explicitly out of scope (being sunset). The bytecode compiler still benefits from parser/typechecker diagnostics, but its own post-typecheck lowering remains first-error.

## Decisions

- **Stage gating:** run the next stage only if the previous stage produced no diagnostics.
  - scan + parse -> stop if parse/scan errors
  - typecheck/analyze -> stop before native emission if type errors
  - native emit -> collect all emitter errors, then stop before invoking `zig`
- **Recovery depth:**
  - parser: statement/block boundaries; first error inside a single statement/expression
  - typechecker: expression-level recovery (both call args, both operands, all struct fields/array elements, etc.) plus statement/function/declaration boundaries
  - native emitter: top-level declaration, global, closure, function, and statement boundaries; no expression-level recovery inside emitted Zig
- **Scanner:** recover from unexpected characters, unterminated strings/templates, invalid register/member tokens; keep scanning and push EOF.
- **Imports:** collect scan/parse errors across all imports; a failed module becomes an empty/unknown namespace and resolving continues with the next import.
- **Output:** sort by path/line/column, dedupe identical path/line/column/message, cap at `max-errors` (default 100; `0` = unlimited), then print a summary. `--max-errors` and `LLTS_MAX_ERRORS` control the cap.
- **LSP:** no LSP feature work. The shared collector may benefit LSP later, but LSP behavior is not part of this change beyond keeping existing tests green.

## Architecture

### 1. Shared diagnostic collector

Extend `src/errors/diag.zig` (or add `src/errors/collector.zig` and re-export from `src/root.zig`) with:

```zig
pub const Diagnostic = struct {
    path: []const u8,
    source: []const u8,       // borrowed; valid for the compile
    line: u32,
    column: u32,
    message: []u8,            // owned
    frames: []Frame = &.{},   // owned import/backtrace frames
    severity: enum { err, warning } = .err,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    cap: usize = 100,
    truncated: usize = 0,
    seen: std.StringHashMap(void),
};

pub fn setActive(c: ?*Collector) void;
pub fn getActive() ?*Collector;
pub fn clearActive() void;
```

Collector methods:

- `add(path, source, line, column, message)` — duplicate message, dedupe, respect cap.
- `addFrame(path, line, column, name)` — attach to the last diagnostic.
- `hasErrors() bool`
- `reportAll() void` — sort, dedupe, print with the existing caret/`-->` format, print frames, print `Compilation failed with N error(s).`, print suppressed-count note when capped, and call `diag.markEmitted()`.
- `deinit()`

Integration with existing reporting:

- `report.reportSourceError`, `reportSourceWarning`, `reportSourceErrorWithFrame`, `reportLocationFrameCol`, `reportCompileMessage` check `diag.getActive()` first. When active, record instead of printing.
- `reportLocationFrameCol` attaches a frame to the last diagnostic when active; otherwise prints as today.
- `diag.wasEmitted()` continues to work; `reportAll` marks it.
- Warnings do not count toward the error cap and retain current behavior (print immediately or record with severity warning; do not fail the compile).

### 2. Pipeline ownership

Add `max_errors: usize = 100` to `RunOptions` and `EmitZigOptions`.

In `src/pipeline.zig`:

- `compileSource`: create collector, `diag.reset()`, `diag.setActive(&collector)`, defer cleanup; scan -> parse -> copy parser diagnostics -> stage gate -> `compiler.analyze`; if clean, run bytecode emit (unchanged).
- `emitZigCode`: same setup; after `compiler.analyze`, check collector; run `zig_backend.emitRuntimeZig`; check collector; only then return success.
- `compileNativeBinary`/`runNativeBinary`: rely on `emitZigCode`; do not write the staged Zig file or invoke `zig` when the collector has errors.
- Clear the active collector before executing VM/native code so runtime errors keep their current immediate formatting.
- Return `error.CompilationFailed` after `reportAll`; CLI catch sees `diag.wasEmitted()` and exits 1 without a duplicate generic message.

### 3. Scanner recovery

In `src/scanner/root.zig`:

- `failScan` keeps reporting/recording and returns the existing `ScanError`.
- `scanAll` catches recoverable scan errors, records them, guarantees forward progress (advance at least one byte if the failed helper consumed nothing), and continues.
- Unterminated string/template: skip to the end of the line/file as appropriate, then continue.
- Invalid member/register/compiler-keyword forms: skip the offending token and continue.
- Always push `.eof`; only `OutOfMemory` remains fatal.
- `scan` returns partial tokens; callers check `collector.hasErrors()`.

### 4. Parser recovery

In `src/parser`:

- `buildAst` already recovers when `diagnostics != null`; keep that path and ensure `synchronize` always makes progress.
- Add `synchronizeBlock` (stop at `;` or a statement-start keyword, but **do not consume `}`**) and use it in `parseBlock` and other statement/block loops.
- `parseBlock`: catch `error.ParseFailed` per statement, record is already done, synchronize to the next statement/`}`, continue. If recovery cannot make progress, advance one token and continue.
- Pass a diagnostics list from `pipeline.compileSource`/`emitZigCode`; after parse, copy `doc.diagnostics` into the active collector (path/source from the doc).
- Audit `return error.ParseFailed` paths that lack a diagnostic (notably `consume`/`advance` at EOF) and replace them with `failMsg("Unexpected end of input")` or `failTok`.
- Keep the existing parser API: callers passing `null` still fail on the first error.

### 5. Typechecker recovery

In `src/compiler/typecheck/root.zig`:

- Add helpers near `inferExpr`/`checkStmt`:

```zig
const Recovered = struct { ty: ir.Type, ok: bool };
fn inferExprRecover(state, env, ta, node) Recovered;
fn checkStmtRecover(state, env, ta, node) ?ir.Type;
```

- `inferExprRecover` catches `error.CompileError`, returns `{ .ty = ir.TUnknown, .ok = false }`; other errors propagate.
- Convert aggregate expression inference to recover each child independently:
  - call callee and every argument
  - binary/unary operands
  - member object, index object/index/end
  - array elements, struct-init fields
  - assignment lhs/rhs, return value, condition/branch expressions
  - `try`/`unwrap` operand
- If any child failed, the parent returns `ir.TUnknown` without reporting a dependent operator/field/arity error. Use `ir.isUnknown`/`ir.involvesUnknown` guards.
- Recover at declaration/function/field/statement boundaries:
  - `checkFunction` body statement loop: `checkStmtRecover`; continue with later statements.
  - `checkStructFieldTypes`: per field; on failure record and use `ir.TUnknown` for that field, continue.
  - `typecheck` loops (struct fields, signatures, function bodies, top-level statements, pending generic instances): catch per item and continue.
  - failed declarations: define the name in the local env as `ir.TUnknown` so later uses do not cascade into "undeclared".
  - failed function signatures: keep the function registered with unknown param/return types; still check the body where possible.
- If the collector has errors, skip `requireEntryMain`, reachability, `binding_facts`, `range_facts`, `recordControlFlowFacts`, and `verifyTypeCaches`; return the partially populated state without emitting bytecode/native code.
- Keep `state.last_error_*` updates for compatibility.

### 6. Import recovery

In `src/compiler/modules.zig`:

- `loadModule`:
  - use scanner recovery;
  - parse with a diagnostics list so the whole module is recovered;
  - copy module `doc.diagnostics` into the collector;
  - on module-local scan/parse/type errors, leave the module binding registered as an empty/unknown namespace and return success so `resolveImportsInner` continues with later imports;
  - on file-read/path-resolution failure, record the diagnostic and also continue with other imports (empty module namespace).
- Keep `visited`/`import_from` bookkeeping so import-chain frames still print.
- If any import diagnostic exists, `compiler.analyze` must stop before typecheck/codegen.

### 7. Native emitter recovery

In `src/compiler/codegen/emitter`:

- `failAt`/`failNoLoc` continue to record through the active collector.
- Wrap per-item loops with `catch |err| switch (err) { error.CompileError => continue, else => return err }`:
  - `collectGlobals`: per global
  - `emitGlobalDecls`: per declaration
  - `emitClosures`: per closure
  - `emitFunctions`: per function
  - `emitTopLevel`: per top-level statement
  - `emitTrampolines`: per trampoline
- For a failed statement inside a function:
  - save/restore `indent`, scope/defer/target array lengths, and `params`/binding state where practical;
  - emit `_ = {};`/skip the statement and continue;
  - if scope/defer state cannot be restored safely, abort the rest of that function and continue with the next function.
- `Emitter.emit()` may return success with a non-empty collector; `pipeline.emitZigCode` checks the collector and reports failure. Do not let the CLI write partial Zig output or invoke `zig` after diagnostics.
- Per-function/per-global recovery is enough because typecheck already catches expression-level errors before native emission.

### 8. CLI flag and plumbing

- Add `max_errors` to `src/cli/flags.zig`:
  - `--max-errors <N>` (string-parsed like `--max-memory`)
  - default `100`; `0` = unlimited
  - env fallback `LLTS_MAX_ERRORS`
- Add `common.getMaxErrors(allocator, ctx)` following `getMaxMemory`/`getComptimeMaxLoopIterations`.
- Pass `max_errors` into `RunOptions`/`EmitZigOptions` from:
  - `src/cli/run.zig`
  - `src/cli/build_cmd.zig`
  - `src/cli/dump.zig`
  - `src/cli/emit.zig`
  - `src/cli/pipeline.zig` (`compileToFile`, `dumpFile`, `emitZig`, `compileNativeSource`, `runSource`)
- Add the flag to `addCompileFlags` and `addEmitZigFlags` so `run`, `build`, `dump`, and `emit-zig` all expose it.

## Implementation Order

1. Add collector + `diag` active integration and unit tests for sorting/dedupe/cap.
2. Scanner recovery and scanner tests.
3. Parser block recovery, EOF diagnostic audit, pipeline copy of parser diagnostics.
4. Typechecker recovery helpers and loop/aggregate conversion.
5. Import recovery in `modules.zig`.
6. Native emitter per-item recovery.
7. Pipeline stage gating, `max_errors` options, CLI flag.
8. Tests and validation.

## Validation

- Unit/integration:
  - `zig build test`
  - `zig build suite-test`
  - `zig build native-test`
  - `zig build`
- New tests:
  - scanner: two lexical errors -> two diagnostics, partial token stream, parser still runs
  - parser: two bad statements in one function and two at top level -> all reported; `}` not consumed
  - typechecker: two bad call args in one call, two bad statements in one function, two bad struct fields -> all reported
  - imports: two broken modules -> both reported, other imports still resolve
  - native emitter: two unsupported functions/types -> both reported, `zig` not invoked
  - CLI: `llts run` on a multi-error file prints all diagnostics sorted, exits 1; `--max-errors 1` prints one plus suppression note; `--max-errors 0` prints all
  - existing `tests/compile_fails` single-error fixtures still pass with unchanged formatting
- Manual checks:
  - `llts run /tmp/multi.lls` (two undefined variables) -> both errors
  - `llts run --native /tmp/multi.lls` -> both type errors, no zig subprocess
  - `llts emit-zig /tmp/multi.lls` -> no partial `.zig` written on stdout/file
  - `llts build /tmp/multi.lls` -> parser/typecheck multi-error behavior; bytecode lowering still first-error by design

## Risks / Constraints

- Typecheck recovery is the highest-risk part: `ir.TUnknown` can trigger cascading strict-mode errors. The aggregate `ok` flag and `involvesUnknown` guards are required; do not simply swallow errors.
- Do not change single-error message formatting; existing fixtures assert on it.
- Parser recovery must never consume the closing `}` of the block being recovered.
- Native emitter recovery must not leave the emitter scope/binding tables corrupted; when unsure, abandon the current function rather than risk a panic.
- Bytecode/VM recovery is out of scope; do not add stack/scope snapshot logic there.
- LSP is out of scope; do not add LSP-specific APIs or diagnostics plumbing, but keep existing LSP tests passing.