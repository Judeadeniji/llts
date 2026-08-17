# LLVM backend status

Experimental AOT path: `llts emit` → bitcode (optional `--emit-llvm` for textual IR).

## Working

- Per-expression types from typecheck (`type_of_results`); no silent `i64` when a type is known
- Annotated integer/float widths, binops, comparisons, short-circuit `&&` / `||`
- Free functions with annotated ABI, globals wired through `__llts_main`
- `print` → C `printf`
- Struct values, `Struct::method` mangling, basic field load/store
- Fixed arrays / index, range `for`, cond `for`, switch (OR patterns)
- Intrinsics: `@as`, `@sizeOf`, `@new` (malloc), `@isError` (stub)
- `defer` (errdefer only on explicit error path — limited)
- Module verify on emit; drop unused clang link (LLVM 21 only)

## VM-only / partial (not full parity)

| Feature | Notes |
|---------|--------|
| Full `std` / `@import` values | Imports resolved for names; module *values* and most std APIs are not lowered |
| First-class functions / closures | Function pointers partially; no captures |
| String concat / rich formatting | `print` only; no `OP_STRING_ADD` equivalent |
| Error unions / try | Soft stubs (`error` → tagged i64) |
| Escape analysis / arenas | `@new` uses `malloc` |
| Pipes, shapes, pow `**` | Unsupported or undef |
| `--release` LLVM opts | Flag accepted for analyze debug; no PassBuilder pipeline yet |
| Object/exe emit | Use `scripts/emit-run.sh` (clang links `.bc`) |

Smoke: `examples/llvm_arith.lls`, `examples/llvm_methods.lls` via `scripts/emit-run.sh`.
