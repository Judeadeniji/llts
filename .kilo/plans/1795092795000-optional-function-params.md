# Optional Function Parameters (TS-style)

## Goal

Support optional function parameters in LLTS using TypeScript-style `?` syntax:

```llts
@func greet(name?: string) {
    if (name != null) { print("Hello, {name}!"); }
    else { print("Hello, stranger!"); }
}
```

Callers may omit trailing optional args; omitted args become `null` at runtime. There is no `undefined` in LLTS (and none planned), so the only default value is `null`.

## Decisions

- **Syntax:** `name?: T` — `?` marker goes after the param name and before the type annotation. `name?` (no annotation) is allowed only in non-strict mode.
- **Placement:** Optional params must be trailing. Once a `?` param appears, every subsequent param must also be optional. `f(x?, y: int)` is a parse error (no way to skip `x` positionally with no `undefined`).
- **`f(x?: ?T)` vs `f(x?: T)`:** Both valid and both collapse to body type `?T` (`T | null`). Optional-wrapping is idempotent: `(T | null) | null = T | null`. `f(x?: ?T)` is accepted but redundant; `f(x?: T)` is idiomatic.
- **Arity:** Minimum args = count of required (non-optional) params. Calling with fewer is a type error. Missing trailing optional args are not checked; they become `null` at runtime.
- **Rest/variadic interaction:** Optional params can precede a rest param: `f(x?: int, ...rest: string[])`. The `?` does not affect rest behavior.
- **Runtime:** Missing trailing args surface as `Value.null` automatically — `src/vm/execute/vars.zig:33` already returns `Value.null` for out-of-range slots. The native backend must emit `null` for each missing trailing param so the Zig function receives its full declared arity.
- **IR type:** An optional param `x?: T` has IR type `?T` = `T | null`. A required nullable param `x: ?T` also has IR type `?T`; they differ only in arity semantics, tracked via `param_is_optional`.

## Files to Change

### 1. `src/ast/stmt.zig` (AST node)
Add `is_optional: bool = false` to the `Param` struct:

```zig
pub const Param = struct {
    name: []const u8,
    type_annotation: ?*Node = null,
    is_rest: bool = false,
    is_optional: bool = false,   // NEW
    loc: Location,
};
```

### 2. `src/parser/decl.zig` (parser)
In `parseParamsList` (`src/parser/decl.zig:140-183`):
- After consuming the param name, accept a `?` delimiter token → set `is_optional = true`. (`?` is already a delimiter per `src/scanner/keywords.zig:27`; `.?` at line 241-246 is a separate token and won't conflict.)
- Enforce trailing: once `is_optional` is true, any later param without `?` is a parse error: `"Required parameter '{s}' cannot follow optional parameter '{s}'"`.
- Add `.is_optional = is_optional` to the appended `Param`.

`$`/`name` token used for diagnostics; preserve `loc`.

### 3. `src/compiler/state.zig` (compiler state)
Add `param_is_optional: []bool = &.{}` to `FunctionDef` so call-site arity checks can distinguish optional `?T` from required nullable `?T`:

```zig
pub const FunctionDef = struct {
    ...
    param_irs: ?[]const ir.Type = null,
    rest_ir: ?ir.Type = null,
    is_variadic: bool = false,
    param_is_optional: []bool = &.{},   // NEW
    ...
};
```

### 4. `src/compiler/typecheck/root.zig` (typechecker)

**A. `fnParamTypes`** (`src/compiler/typecheck/root.zig:1355-1417`) and **the inline param loop** (`src/compiler/typecheck/root.zig:4238-4279`):
For `is_optional` params, wrap the IR type in `?T`:

```zig
if (pnode.is_optional) {
    t = try ta.unionType(&.{ t, ir.TNull });
}
```

Place this after resolving `t` from the annotation (or `TUnknown`), before appending to `params_buf` / `out_params`. Also record `def_ptr.param_is_optional` in the `FunctionDef` update block (`root.zig:4280-4285`).

**B. `checkFuncValueCall`** (`src/compiler/typecheck/root.zig:3545-3575`):
Change the exact-arity check to a minimum-arity check:

```zig
const required_count = count of params where !def.param_is_optional[i];  // NEW
if (!f.variadic and any_annotated and c.args.len < required_count) {
    const d = try ownDisplay(state, fn_ty);
    return compiler_errors.compileFailFmt(
        state, "Function value '{s}' expected at least {d} arguments, got {d}", .{ d, required_count, c.args.len });
}
```

The existing loop already handles `c.args.len > named_count` (extra args inferred, unchecked) and `i < c.args.len` for trailing extras. Missing trailing optional params are unchecked — they're `null` at runtime, valid for `?T`.

### 5. `src/compiler/codegen/emitter/expr.zig` (native backend)
**`emitCallArguments`** (`src/compiler/codegen/emitter/expr.zig:101-190`):
In the non-variadic path (`root.zig:126-136`), if `args.len < named_param_count`, append `null` for each missing trailing param so the Zig function is called with its full declared arity:

```zig
if (!is_variadic) {
    for (args, 0..) |arg, i| {
        ...
    }
    // NEW: fill missing trailing optional params with null
    while (args.len < named_param_count) {
        try args_buf.append(a, "null");
        args.len += 1;  // track logically
    }
    return;
}
```

Careful: `args` is a slice; use a local counter instead of mutating. The `named_param_count` already excludes variadic/rest. Missing optional params after the last provided arg get `null`.

VM path: no change needed — `vars.zig:33` returns `Value.null` for out-of-range slots.

## Validation

- **Tests to add** (in `tests/suite/typecheck_test.zig` or a new file):
  - `f(x?: T)` callable with and without `x`; body sees `null` when omitted.
  - `f(x: int, y?: string)` — `y` trailing optional works; `f(1)` OK; `f(1, "hi")` OK.
  - `f(x?: string, y: int)` → parse error (required after optional).
  - `f(x?: ?T)` accepted, equivalent to `f(x?: T)`.
  - `f(x?: int, ...rest: string[])` — optional before rest works.
  - Arity: `f(x: int, y: int)` called as `f(1)` → type error (missing required).
  - Native backend: emit `--native` and `emit-zig` for a function with optional params, verify generated Zig passes `null` for omitted args.
  - `zig build test`, `zig build suite-test`, `zig build native-test`.

- **Existing fixtures:** ensure `tests/compile_fails` single-error formatting unchanged; no existing tests use `?` params, so no regressions expected.

## Risks / Constraints

- `ir.TUnknown` handling: if an optional param is unannotated in non-strict mode, its IR type is `TUnknown`; wrapping gives `TUnknown | null`. Ensure `unionType` accepts `TUnknown`.
- `param_is_optional` must stay in sync with `param_irs` length — both indexed by param position.
- The emitter's `null` fill-in must not break variadic/rest path (already handled separately).
- Strict mode requires annotations; `f(x?)` without annotation in strict mode → existing "must have an explicit type annotation" error.
- VM path needs no change (out-of-range → `Value.null`), but verify `callStatic`/`callDynamic` arity checks don't reject optional-omitted calls at runtime (they shouldn't; arity check is against declared `arg_count`, and emitted calls pass full arity).

## Implementation Order

1. AST: add `is_optional` to `Param`.
2. Parser: parse `?` + enforce trailing ordering; add test.
3. State: add `param_is_optional` to `FunctionDef`.
4. Typecheck: wrap optional param type in `?T`; record `param_is_optional`; change arity check to minimum; add tests.
5. Emitter: emit `null` for missing trailing optional params; add native/emit-zig test.
6. Run full test suite.

## Out of Scope

- No `undefined` keyword or value.
- No named/default-argument syntax (`f(x: T = 5)`).
- No LSP changes (keep existing tests green).
- No bytecode/VM stack changes (already returns `null` for missing slots).
