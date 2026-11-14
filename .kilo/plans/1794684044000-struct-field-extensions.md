# LLTS Struct Field Syntax Extensions

## Goal

Add field-level modifiers to LLTS `@struct` declarations: explicit defaults, readonly fields, and `pub` visibility (module-private default). Nullable fields (`?T`) already exist; this plan enforces that `?T` does **not** imply an implicit `null` default. Missing required keys in struct literals remain a compile error (already enforced in `--strict`).

Data-only features — no inheritance, no `this`, no virtual dispatch, no access-modifier OOP.

## Decisions (all resolved)

| Decision | Resolution |
|----------|-----------|
| Visibility keyword | `pub` only; absence = module-private; no `priv` keyword |
| Readonly keyword | `readonly` before field name; construction initializes, post-construction assignment rejected |
| Defaults | `= <compile-time expr>` explicit; `?T` does not imply `null` |
| Missing key | Compile error in `--strict`; defaulted fields exempt |
| Visibility boundary | Compare struct-name module prefix vs `state.chunk.file`; cross-module + non-`pub` → error |
| Default storage | Store `default: ?*Node` (AST pointer) in `FieldMetadata`; evaluate at emit time |
| Index signatures | Out of scope |
| Tests | Native Zig only (`tests/native.zig`, `tests/compile_fails/`, `tests/suite/parser_test.zig`); no TS tests |

## Syntax

```lls
@struct Account {
    pub id: i64;              # cross-module accessible
    balance: f64 = 0.0;       # module-private, explicit default
    readonly created_at: i64; # module-private, set once at construction
    email: ?string = null;    # nullable, explicit default
    tag: ?string;             # nullable, required (no implicit null)
}

pub @func main() {
    $a = Account { id: 1, created_at: 1234567890 };
    a.balance = 100.0;        # ok (same module)
    # a.created_at = 999;     # error: readonly
    # $a2 = Account { id: 2 };# error: missing required 'tag'
}
```

Grammar:

```
FieldDecl ::= ("pub")? ("readonly")? Identifier ":" Type ("=" Expression)? ";"
```

## Affected files

| File | Change |
|------|--------|
| `src/ast/stmt.zig` | `StructField`: add `is_public`, `is_readonly`, `default: ?*Node` |
| `src/ast/clone.zig` | Deep-clone `default` node |
| `src/parser/structs.zig` | Parse `pub`, `readonly`, `= default` |
| `src/compiler/state.zig` | `FieldMetadata` struct + `StructDef.field_metadata` map |
| `src/compiler/typecheck/root.zig` | `checkOneStructField` (validate defaults); `checkInitAgainstStruct` (exempt defaulted fields); `inferMemberExpr` (visibility check) |
| `src/compiler/expr/assign.zig` | `assignMember` (reject readonly assignment) |
| `src/compiler/stmt/decl.zig` | Move `field_metadata` when `StructDef` is replaced |
| `src/compiler/codegen/emitter/root.zig` | `StructType.StructField`: add `is_readonly`, `default_zig`; `ensureStructType` populate |
| `src/compiler/codegen/emitter/stmt.zig` | `emitAssignment` readonly assertion |
| `src/compiler/codegen/emitter/expr.zig` | `emitStructLiteral`: use default instead of `zeroValue` |
| `tree-sitter-llts/grammar.js` | Update struct field rule |
| `docs/types/user-defined.md` | Document new syntax |
| `TODO.MD` | Add remaining struct work |

## Architecture

### 1. AST (`src/ast/stmt.zig`)

```zig
pub const StructField = struct {
    name: []const u8,
    type_annotation: ?*Node,
    is_public: bool = false,
    is_readonly: bool = false,
    default: ?*Node = null,
};
```

Clone `default` in `src/ast/clone.zig` (it's an arena-owned pointer; shallow copy of the pointer is fine).

### 2. Parser (`src/parser/structs.zig`)

In `parseCompilerStruct`, before consuming field name:

1. If next token is `pub` and token after is an identifier (not `:`), consume `pub`, set `is_public = true`. Edge case: `pub pub: i64;` — `pub` followed by `:` is not a modifier.
2. If next token is `readonly` and token after is `:`, consume `readonly`, set `is_readonly = true`.
3. Consume field name, `:`, type.
4. Optionally consume `=` then expression, then `;`.

### 3. State (`src/compiler/state.zig`)

```zig
pub const FieldMetadata = struct {
    is_public: bool = false,
    is_readonly: bool = false,
    default: ?*ast.Node = null,   // arena-owned; no deinit needed
};

pub const StructDef = struct {
    name: []const u8,
    size: i32,
    offsets: std.StringHashMap(i32),
    types: std.StringHashMap([]const u8),
    field_irs: std.StringHashMapUnmanaged(ir.Type) = .{},
    field_metadata: std.StringHashMap(FieldMetadata) = .{},
};
```

### 4. Typecheck — field declaration (`checkOneStructField`)

In `typecheck/root.zig` `checkOneStructField` (line 4727):

- If `field.default` present, validate with `const_eval.evalExpr(state, null, field.default)`. Return null → error `"Default expression must be constant"`.
- Also typecheck default against field type via `assignRec`.
- Store `FieldMetadata` in `def.field_metadata`.

### 5. Typecheck — struct literal (`checkInitAgainstStruct`)

In `typecheck/root.zig` `checkInitAgainstStruct` (line 3671):

- Skip missing-field error for fields with `default` in `def.field_metadata`.
- Update error message: "provide it in the initializer, declare the field optional ('?T'), or give it a default value".

### 6. Typecheck — readonly assignment (`expr/assign.zig`)

In `assignMember` (line 89), after `types.lookupStructField`:
- If `def.field_metadata.get(field_name)?.is_readonly` → error `"Cannot assign to readonly field '{s}'"`.

### 7. Typecheck — visibility (`inferMemberExpr` in `typecheck/root.zig`)

When `ir.structNameOf(obj)` returns `sname` containing `::`:
- Split `sname` on `::`; module prefix is the part before `::`.
- Current module = `state.chunk.file`.
- If `module_prefix != state.chunk.file` and `def.field_metadata.get(field_name)?.is_public == false` → error `"Field '{s}' is private to module '{s}'"`.

### 8. Emitter — struct type (`emitter/root.zig`)

```zig
pub const StructField = struct {
    name: []const u8,
    zig_name: []const u8,
    display: []const u8,
    vt: ValType,
    offset: i32,
    is_readonly: bool = false,
    default_zig: []const u8 = "",
};
```

In `ensureStructType`, look up `def.field_metadata.get(seed.name)`; set `is_readonly`. Compute `default_zig` by evaluating `default` node with `const_eval.evalExpr(state, null, node)` and converting `ConstValue` to Zig text (pattern after `constValueZig` in `unit.zig`).

### 9. Emitter — struct literal (`emitter/expr.zig`)

In `emitStructLiteral` (line 1977), missing field: if `field.default_zig` non-empty, use it; else `zeroValue`.

### 10. Emitter — readonly assertion (`emitter/stmt.zig`)

In `emitAssignment` member path, check `field.is_readonly` → diagnostic. Backstop for typecheck.

### 11. `stmt/decl.zig` StructDef replacement

When `StructDef` is replaced (line 387-399), move `field_metadata` from old to new (pointer-only map, no deinit needed).

### 12. Layout

No change.

## Implementation order

1. AST fields + clone
2. Parser (`pub`, `readonly`, `= default`)
3. State `FieldMetadata` + `StructDef.field_metadata`
4. Typecheck field declaration validation
5. Typecheck missing-field exemption for defaulted fields
6. Typecheck readonly assignment rejection
7. Typecheck visibility module boundary
8. `stmt/decl.zig` field_metadata move on StructDef replace
9. Emitter `StructField` metadata + `ensureStructType`
10. Emitter default substitution in `emitStructLiteral`
11. Emitter readonly assertion
12. Tree-sitter grammar
13. Docs + TODO

## Validation — native Zig only

```sh
zig build
zig build test
```

### `tests/native.zig`

Happy paths (`expectNativeEmitContains`):
- Default used when field omitted → `.balance = 0.0`
- Readonly struct literal → `x` field emitted

Happy paths (`runNativeSource`):
- Prints default value when field omitted
- Prints readonly field value after construction
- `?string = null` default → `true` when compared to null

Cross-module (`expectCompileFail` + positive):
- Module A `pub @struct S { pub id: i64; secret: i64; }`; Module B `print(s.secret)` → error
- Module B `print(s.id)` → compiles OK

Compile-fail (`expectCompileFail`):
- Readonly assignment: `Cannot assign to readonly field 'x'`
- Missing nullable field: `Missing required field 'email'`
- Missing `?T` without default: `Missing required field 'tag'`
- Non-const default: `Default expression must be constant`

### `tests/compile_fails/*.lls`

`readonly_assign.lls`, `missing_nullable_field.lls`, `implicit_null_default.lls`, `non_const_default.lls`, `missing_defaulted_field_ok.lls` (positive — should compile)

### `tests/suite/parser_test.zig`

- `pub f64;` → public field
- `readonly f64;` → readonly field
- `f64 = 5;` → default
- `pub readonly f64 = 5;` → both
- `pub pub: i64;` → field named `pub` (edge case)

## Risks

- **`default_zig` re-emission:** `const_eval.evalExpr` at emit time must succeed (validated at typecheck). Const values from `state.const_values` (module-level `@const`) are accessible with `null` scope.
- **Module boundary:** `state.chunk.file` is set in both `analyze` and `prepareForTypecheck`. Struct names are qualified with `moduleKey(path)` = path with `.lls` suffix; comparison `module_prefix == state.chunk.file` should match.
- **`StructDef` replacement:** `field_metadata` contains arena-owned node pointers; move the map without deinit when replacing `StructDef`.
- **Existing tests:** All existing `@struct` tests must pass; new fields are optional.

## Out of scope

- Index signatures, `priv` keyword, implicit `null` default for `?T`, non-const defaults, shape field modifiers, method visibility, TS tests.
