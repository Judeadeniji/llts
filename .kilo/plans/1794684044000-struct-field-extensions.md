# LLTS Struct Field Syntax Extensions

## Goal

Add field-level modifiers to LLTS `@struct` declarations: explicit defaults, readonly fields, and `pub`/`priv` visibility (with `pub` explicit and module-private as the default). Nullable fields (`?T`) already exist; this plan enforces that `?T` does **not** imply an implicit `null` default. Missing required keys in struct literals remain a compile error (already enforced in `--strict`).

These are data-only features — no inheritance, no `this`, no virtual dispatch, no access-modifier OOP.

## Decisions

- **Visibility keyword:** `pub` is the only visibility modifier. Writing `pub` makes a field accessible from other modules; omitting it makes the field module-private. There is no `priv` keyword.
- **Readonly keyword:** `readonly` precedes the field name. It is a compile-time immutability rule on the field; construction `S { x: ... }` still initializes it, but `s.x = ...` after construction is rejected.
- **Defaults:** explicit `= <compile-time expr>` after the field type. `?T` does **not** default to `null`; a nullable field without a default is still required at construction.
- **Missing key:** compile error (already in `--strict` via `checkInitAgainstStruct`). Fields with defaults are exempt from the missing-field error.
- **Index signatures:** out of scope (key type undecided; maps are a separate future feature).
- **Visibility boundary:** use struct-name qualification as proxy. Qualified (`mod::Name`) = cross-module access → reject non-`pub` fields. Unqualified (`Name`) = same module → allow all fields. No per-statement module tracking.

## Syntax

```lls
@struct Account {
    pub id: i64;              # accessible from other modules
    balance: f64 = 0.0;       # module-private (default), explicit default
    readonly created_at: i64; # module-private, set once at construction
    email: ?string = null;    # nullable, explicit default
    tag: ?string;             # nullable, required (no implicit null)
}

pub @func main() {
    $a = Account { id: 1, created_at: 1234567890 };
    # balance defaults to 0.0, email defaults to null, tag is required → error if omitted
    a.balance = 100.0;        # ok (same module)
    # a.created_at = 999;     # error: readonly field
    # $a2 = Account { id: 2 };# error: missing required field 'tag'
}
```

Grammar additions (struct field declaration):

```
FieldDecl    ::= ("pub")? ("readonly")? Identifier ":" Type ("=" Expression)? ";"
```

## Affected files

| File | Role |
|------|------|
| `src/ast/stmt.zig` | `StructField` AST: add `is_public`, `is_readonly`, `default` |
| `src/ast/clone.zig` | Deep-clone new `StructField` fields |
| `src/parser/structs.zig` | Parse `pub`, `readonly`, `= default` on fields |
| `src/compiler/state.zig` | `StructDef`: add `field_metadata` map; `FieldMetadata` struct |
| `src/compiler/typecheck/root.zig` | `checkOneStructField`: validate defaults; `checkInitAgainstStruct`: skip missing-field error for defaulted fields; `inferMemberExpr`: visibility check |
| `src/compiler/expr/assign.zig` | `assignMember`: reject assignment to readonly fields |
| `src/compiler/expr/path.zig` | `currentModulePath`: already exists; visibility module boundary |
| `src/compiler/codegen/emitter/root.zig` | `StructType.StructField`: add `is_readonly`, `default_zig`; `ensureStructType`: populate from metadata |
| `src/compiler/codegen/emitter/stmt.zig` | `emitAssignment`: reject readonly field assignment (emitter assertion) |
| `src/compiler/codegen/emitter/expr.zig` | `emitStructLiteral`: use default instead of `zeroValue` for missing defaulted fields |
| `src/compiler/layout.zig` | No change (defaults don't affect layout) |
| `tree-sitter-llts/grammar.js` | Update struct field rule |
| `docs/types/user-defined.md` | Document new field syntax |
| `docs/types/structs-vs-shapes.md` | Update field table if needed |
| `TODO.MD` | Add remaining struct work |

## Architecture

### 1. AST (`src/ast/stmt.zig`)

Extend `StructField`:

```zig
pub const StructField = struct {
    name: []const u8,
    type_annotation: ?*Node,
    is_public: bool = false,       # `pub` keyword present
    is_readonly: bool = false,     # `readonly` keyword present
    default: ?*Node = null,        # `= <expr>` default expression
};
```

Update `src/ast/clone.zig` to deep-clone `default`.

### 2. Parser (`src/parser/structs.zig`)

In `parseCompilerStruct`, before consuming the field name:

1. Check if the next two tokens are `pub` followed by an identifier (not `:`). If so, consume `pub` and set `is_public = true`. Edge case: a field literally named `pub` — `pub` followed by `:` is a modifier; `pub` followed by another identifier is a field named `pub`.
2. Check if the next token is `readonly` followed by `:`. If so, consume `readonly` and set `is_readonly = true`.
3. Consume field name, `:`, type.
4. Optionally consume `=` then an expression (the default), then `;`.

Store all three flags plus the default node in `ast.StructField`.

### 3. State (`src/compiler/state.zig`)

Add:

```zig
pub const FieldMetadata = struct {
    is_public: bool = false,
    is_readonly: bool = false,
    default_display: []const u8 = "",  # LLTS source text of the default
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

`default_display` stores the LLTS source text so it can be re-emitted at emit time. Since defaults are compile-time constants, this text is simple enough to emit directly (literals, const references).

### 4. Typecheck — field declaration (`checkOneStructField`)

In `src/compiler/typecheck/root.zig`, `checkOneStructField` (line 4727):

- If `field.default` is present, typecheck the default expression against the field's declared type using `inferInitAgainstType` / `assignRec`.
- Reject defaults that are not compile-time constant expressions (literals, `@const` bindings, const-foldable calls). Use `const_eval.evalExpr` to validate const-ness; reject anything that doesn't evaluate to a constant.
- Store `FieldMetadata { .is_public, .is_readonly, .default_display = <source text> }` in `def.field_metadata`.

### 5. Typecheck — struct literal initialization (`checkInitAgainstStruct`)

In `checkInitAgainstStruct` (line 3625):

- In the strict-mode missing-field check (line 3671-3698), skip fields that have a default in `def.field_metadata`. A defaulted field is not "required".
- The error message for missing required fields already mentions declaring the field optional (`?T`); add "or give it a default value".

### 6. Typecheck — readonly assignment (`src/compiler/expr/assign.zig`)

In `assignMember` (line 89), after resolving the field via `types.lookupStructField`:

- Look up `info.def.field_metadata.get(field_name)`.
- If `is_readonly` is true, reject with `"Cannot assign to readonly field '{s}'"`.
- This check applies regardless of `arith` (compound or plain assignment).

### 7. Typecheck — field visibility (`inferMemberExpr` in `typecheck/root.zig`)

When `ir.structNameOf(obj)` returns a struct name:

- If `sname` contains `::`, the owning module is the prefix before `::`.
- Determine current module path via `state.diag_path` (set during typecheck at line 1518) or `state.chunk.file`.
- If `def.field_metadata.get(field_name)` has `is_public == false` and the struct's owning module differs from current module, reject with `"Field '{s}' is private to module '{s}'"`.

### 8. Emitter — struct type (`src/compiler/codegen/emitter/root.zig`)

Extend `StructType.StructField`:

```zig
pub const StructField = struct {
    name: []const u8,
    zig_name: []const u8,
    display: []const u8,
    vt: ValType,
    offset: i32,
    is_readonly: bool = false,
    default_zig: []const u8 = "",  # pre-emitted Zig code for the default
};
```

In `ensureStructType` (line 286), after building each field, look up `def.field_metadata.get(seed.name)` and set `is_readonly` and `default_zig`.

`default_zig` is computed from `default_display`:
- Numeric literal → emit as-is
- String literal → emit via `zigString`
- `true`/`false` → emit as-is
- `null` → emit as `null`
- Const reference → look up the const's value and emit it
- Anything else → emitter diagnostic "unsupported default expression"

### 9. Emitter — struct literal (`src/compiler/codegen/emitter/expr.zig`)

In `emitStructLiteral` (line 1977), when a field is not provided in `si.fields`:

- If `field.default_zig` is non-empty, use it instead of `zeroValue(self, field.vt)`.
- Otherwise, use `zeroValue` as today.

### 10. Emitter — readonly assignment assertion (`src/compiler/codegen/emitter/stmt.zig`)

In `emitAssignment` member path (line 62-77), check `field.is_readonly`. If true, emit a diagnostic `"Cannot assign to readonly field '{s}'"`. This is a backstop; typecheck should catch it first.

### 11. Layout

No change. Defaults do not affect field offsets or size. Nullable fields (`?T`) already occupy handle-sized storage (8 bytes) per `layout.zig`.

## Implementation order

1. AST fields + clone (`src/ast/stmt.zig`, `src/ast/clone.zig`)
2. Parser (`src/parser/structs.zig`) — `pub`, `readonly`, `= default`
3. State `FieldMetadata` + `StructDef.field_metadata` (`src/compiler/state.zig`)
4. Typecheck field declaration validation (`checkOneStructField`)
5. Typecheck missing-field exemption for defaulted fields (`checkInitAgainstStruct`)
6. Typecheck readonly assignment rejection (`expr/assign.zig`)
7. Typecheck visibility module boundary (`inferMemberExpr` in `typecheck/root.zig`)
8. Emitter `StructField` metadata + `ensureStructType` population (`emitter/root.zig`)
9. Emitter default substitution in `emitStructLiteral` (`emitter/expr.zig`)
10. Emitter readonly assertion (`emitter/stmt.zig`)
11. Tree-sitter grammar + regeneration
12. Docs + TODO updates

## Validation — native Zig tests only (no TS tests)

Run:

```sh
zig build
zig build test
```

### Native tests (`tests/native.zig`)

Add happy-path and compile-fail tests using `expectNativeEmitContains`, `expectCompileFail`, and `runNativeSource`.

**Happy paths — emit:**

| Source | Expected emitted Zig substring |
|--------|-------------------------------|
| `@struct S { pub id: i64; balance: f64 = 0.0; } $s = S { id: 1 };` | `.balance = 0.0` |
| `@struct S { readonly x: i64; } $s = S { x: 1 };` | struct literal with `x` field |

**Happy paths — run (`runNativeSource`):**

| Source | Expected stdout |
|--------|----------------|
| `@struct S { pub id: i64; balance: f64 = 0.0; } $s = S { id: 1 }; print(s.balance);` | `0` |
| `@struct S { readonly x: i64; } $s = S { x: 1 }; print(s.x);` | `1` |
| `@struct S { id: i64; email: ?string = null; } $s = S { id: 1 }; print(s.email == null);` | `true` |

**Cross-module visibility (compile-fail via `expectCompileFail`):**

| Source | Expected error substring |
|--------|-------------------------|
| Module A `pub @struct S { pub id: i64; secret: i64; }`; Module B accesses `s.secret` | `Field 'secret' is private to module` |
| Module A `pub @struct S { pub id: i64; secret: i64; }`; Module B accesses `s.id` | compiles OK |

**Compile-fail fixtures:**

| Source | `# expect:` substring | `# mode:` |
|--------|----------------------|-----------|
| `@struct S { readonly x: i64; } $s = S { x: 1 }; s.x = 2;` | Cannot assign to readonly field 'x' | strict |
| `@struct S { id: i64; email: ?string; } $s = S { id: 1 };` | Missing required field 'email' | strict |
| `@struct S { id: i64; tag: ?string; } $s = S { id: 1 };` | Missing required field 'tag' | strict |
| `@func f(): i64 { return 1; } @struct S { x: i64 = f(); }` | Default expression must be constant | strict |
| `@struct S { pub id: i64; balance: f64; } $s = S { id: 1 };` (in strict, `balance` missing) | Missing required field 'balance' | strict |
| `@struct S { id: i64; balance: f64 = 0.0; } $s = S { id: 1 };` (happy path — should compile) | — | strict |

### Parser tests (`tests/suite/parser_test.zig`)

- `pub f64;` field parses as public field
- `readonly f64;` field parses as readonly field
- `f64 = 5;` field parses with default
- `pub readonly f64 = 5;` both modifiers
- `@struct S { pub id: i64; balance: f64 = 0.0; }` full struct with modifiers
- Field named `pub` (`pub pub: i64;` — `pub` followed by `:` is not a modifier since next token is `:`)

## Risks / Constraints

- **`default_display` re-emission:** Storing LLTS source text and re-emitting it at emit time is simple but limited to literal/const defaults. Non-const defaults should be rejected at typecheck with a clear error. Expand to full const-eval later if needed.
- **Module ownership extraction:** The struct's qualified name (`mod::Name`) encodes the owning module. Parsing `::` to extract it is fragile but consistent with how modules already qualify names. An alternative is adding an `owning_module` field to `StructDef`; defer that decision to implementation.
- **`StructDef` replacement:** In `stmt/decl.zig` line 387-399, the old `StructDef` is `fetchRemove`d and a new one is put. `field_metadata` must be moved from old to new (it's just string slices, no allocation needed) or rebuilt.
- **`checkInitAgainstStruct` does not mutate `init.fields`:** defaults are checked but not injected into the AST. The emitter handles missing defaulted fields at emit time. No AST mutation needed.
- **Existing struct tests:** All existing `@struct` tests must continue to pass. The new fields are optional; existing structs without `pub`/`readonly`/`default` behave identically (module-private fields, mutable, required).
- **`--strict` missing-field check:** Already exists. Only change: defaulted fields are exempt. Non-defaulted `?T` fields remain required.

## Out of scope

- Index signatures (any key type)
- Field-level `priv` keyword (absence of `pub` already means private)
- Implicit `null` default for `?T`
- Non-const default expressions (beyond literals/const refs)
- Structural shape field modifiers (shapes are a different feature)
- Method visibility (methods follow struct-level `pub`)
- TS/Bun test conversion — native Zig tests are the sole validation layer
