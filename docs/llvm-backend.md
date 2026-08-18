# LLVM backend status

Experimental AOT path: `llts emit` → bitcode (optional `--emit-llvm` for textual IR).

## Working

- Per-expression types from typecheck (`type_of_results`); no silent `i64` when a type is known
- Annotated integer/float widths, binops, comparisons, short-circuit `&&` / `||`
- Free functions with annotated ABI, globals wired through `__llts_main`
- `print` → C `printf`
- Struct values, `Struct::method` mangling, basic field load/store
- Fixed arrays / index, range `for`, cond `for`, switch (OR patterns)
- Intrinsics: `@as`, `@sizeOf`, `@new` (arena via `__arena_alloc_bytes`), `@isError` (stub)
- Method receivers passed by reference (`self: *T`), module calls via static-path resolution
- `defer` (errdefer only on explicit error path — limited)
- Module verify on emit; drop unused clang link (LLVM 21 only)
- Native arena runtime (`src/runtime/arena.zig` → `zig-out/lib/llts-runtime.o`):
  `__arena_create` / `__arena_alloc` / `__arena_alloc_bytes` / `__arena_reset` /
  `__arena_deinit`, linked by `scripts/emit-run.sh`
- Native std runtime (`src/runtime/builtins/root.zig` → `zig-out/lib/llts-runtime-natives.o`):
  C-ABI implementations of the `__`-natives backing all std modules,
  split into `{util,len,string,math,fs,syscall,buffer,os,time,list,map,
  json,http,debug}.zig` mirroring the VM's `src/vm/builtins/` layout.
  Full parity surface: `len` / `std/string.lls` / `std/math.lls` /
  `std/fs.lls` / `std/syscall.lls` / `std/buffer.lls` / `std/os.lls` /
  `std/time.lls` / `std/list.lls` / `std/map.lls` / `std/json.lls` /
  `std/http.lls` (libcurl) / `std/debug.lls` (~300 native exports).
  Native strings are C strings; string results are copied into a
  runtime-owned bump heap (VM parity: live until exit); native arrays
  (rest args, `__split`) are count-prefixed (`arr[-1]` = count)
- Error-value ABI: `error(name, payload)` literals and error-returning natives
  lower to `__err_new` (pointer into a runtime error arena); `@isError` →
  `__err_is`, `.code` → `__err_code`, `.payload` → `__err_payload`, so
  `std/fs.lls`'s `mapIo` error chain (`err.code` / `err.payload` / string
  `@switch`) matches the VM byte-for-byte
- Full syscall chain: `__sys_*` natives + `__O_*` / `__SYS_*` / `__F_OK`
  constants (comptime-generated in the natives table), buffer natives
  (`__bufferAlloc` / `__bufferAppend*` / `__bufferReadString` …), `os.exec`/
  `os.cwd`/`os.getEnv`, string-aware `==` / `!=` and `@switch`, and
  fixed+rest wrapper calls (`syscall.open(path, flags, ...mode)`)
- Native signature table `src/compiler/natives.zig`: types native call sites in
  the typechecker (so unannotated std wrappers infer real param/return types)
  and declares natives with real ABI in the backend instead of variadic `i64` stubs
- std module consts via member access (`math.PI`), bool printing (`true`/`false`),
  `len` (arrays → compile-time, strings → `__strlen`, slices → `__arrayLen`),
  rest-arg packing for `min(...args)` / `max(...args)`

## Known gaps (pre-existing, not regression)

| Feature | Notes |
|---------|--------|
| Module *values* | Imports resolved for names; module handles aren't first-class natively |
| First-class functions / closures | Function pointers partially; no captures |
| String concat / rich formatting | `print` only; no `OP_STRING_ADD` equivalent |
| Error unions / try | `error(name, payload)` + `@isError` + `.code`/`.payload` work; `try` on non-void values still limited |
| Escape analysis / arenas | `@new` allocates in the passed-in arena (native runtime); type-arg forms (`@new(a, T)` / `@new(a, []T, n)`) still unlowered |
| `@for` over `[]string` | Split/join results support indexing + `len`, but byte-walk iteration stops at the first NUL; iterate by index |
| JSON array indexing/len | Typechecker treats `json.parse` return as i64, so `len()` / `a[i]` don't route to `__jsonLen`/`__jsonIndex` |
| HTTP struct method calls | `res.status` / `res.body` on HTTP response structs need struct field access working for opaque handles |
| Pipes, shapes, pow `**` | Unsupported or undef |
| `--release` LLVM opts | Flag accepted for analyze debug; no PassBuilder pipeline yet |
| Object/exe emit | Use `scripts/emit-run.sh` (clang links `.bc` + both runtime objects + `-lcurl`) |

Smoke: `examples/llvm_arith.lls`, `examples/llvm_methods.lls`, `examples/llvm_arena.lls`,
`examples/llvm_stdlib.lls`, `examples/llvm_fs.lls` via `scripts/emit-run.sh`. Parity harness:
`scripts/parity-check.sh` runs every len/string/math/fs/syscall/buffer/os/time/list/map/
json test source through both the VM and the LLVM backend and diffs the output
(45 match / 2 mismatch / 24 skipped; mismatches: json array len pre-existing typegap,
http fetch struct access). All 457 bun tests pass (454 pass, 3 pre-existing json array
indexing failures in both VM and LLVM).
