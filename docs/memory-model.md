# LLTS Memory Model (RFC)

**Status:** draft — file created as Track B deliverable. Implementation follows Track A interpreter hot-path work.

**Goal:** efficient CPU use and less memory while staying a light interpreter (no JIT, no tracing GC).

## Current model

| Region | Type | Role |
|--------|------|------|
| Operand stack | Fixed `[]Value` + `sp` | Expression evaluation |
| `vm.memory` | `ArrayList(Value)` | Frame bump; rewind `heap_ptr` on return |
| `vm.immortal` | `ArrayList(Value)` | Escape / arena control / errors |
| `vm.bytes` | `ArrayList(u8)` + `bytes_ptr` / `bytes_immortal_floor` | Unified packed heap: `.slice` strings and `.bytes` `[]byte` |
| Host objects | `List` / `Map` / `Buffer` pointers | Separate heaps |

Pointers into the Value heaps are `Value.ptr: i32` (frame slots from `HEAP_START`, immortal from `IMMORTAL_BASE`).

Struct / value-array layout: **packed byte offsets** in `vm.bytes` (see `src/compiler/layout.zig`). `@sizeOf` reports real sizes.

Relevant code: `src/vm/state.zig`, `src/vm/execute/heap.zig`, `src/vm/builtins/mem.zig`, `src/compiler/widths.zig`.

### Packed byte policy (step 1 — done)

- `allocImmortalBytes` / `appendImmortal` / string builders raise `bytes_immortal_floor`.
- `allocFrameBytes` bumps `bytes_ptr` only; `CallFrame.bytes_watermark` + `rewindPacked` on return reclaim frame bytes down to the immortal floor.
- Strings and `[]byte` share `vm.bytes` (no separate `string_bytes` arena).

## Problems (historical)

1. Uniform `Value` slots wasted memory and cache on aggregates.
2. `@sizeOf` / arenas could not describe real layout.
3. Extra numeric widths could not pay off if everything was still a tagged slot with lying aliases.

## Target model

```
┌─────────────────────────────┐
│ Stack / globals / locals    │  tagged Value (honest widths)
│  i8..i64, u8..u64, f32/f64  │  (+ ptr / slice handles)
│  aliases: int→i64, byte→u8  │
│           float→f64         │
└──────────────┬──────────────┘
               │ ptr / {offset,len}
               ▼
┌─────────────────────────────┐
│ Packed heap (byte region)   │
│  frame_watermark (rewind)   │
│  immortal / pass region     │
│  structs @ byte offsets     │
│  slices = ptr + len         │
└─────────────────────────────┘
```

### Locked rules

1. **Types are what they say** — in source, typechecker, and runtime. A `u8` is a `u8` end-to-end; the VM does not store it as a secret `i64`.
2. **No implicit conversions.** Load, store, and arithmetic must not silently promote or truncate between widths.
3. **Explicit cast only.** Prefer Zig-like `@as(T, expr)`. Truncation/sign behavior is defined at the cast site. Unequal widths without a cast → **compile error**.
4. **Lifetime rules stay:** frame vs immortal vs `@new` / escape errors / `defer` / `errdefer`. Only the storage substrate changes.
5. **No GC. No JIT** in this track.

### Stack numerics

Honest `Value` tags for `i8`…`i64`, `u8`…`u64`, `f32`, `f64`. Language aliases normalize at the type boundary (`int`/`number`→`i64`, `byte`→`u8`, `float`→`f64`); `@typeOf` prints the canonical name.

Integer literals may coerce into any integer width that fits. Float literals are `f64` and may coerce into `f32`. Runtime cross-width ops require `@as` (`OP_AS`).

Example:

```llts
$b: u8 = buf[i];           # stays u8 at runtime
$n: i64 = @as(i64, b);     # only widen
# $n = b;                  # illegal — mixed widths
$x: i32 = 42;              # real i32, not an int alias
```

## Migration order

1. **Packed region beside old heaps** — ✅ unified `vm.bytes` for strings + `[]byte`; frame watermark + immortal floor.
2. **Struct fields as byte layout** — ✅ field byte offsets; `@sizeOf` = real sizes; structs live in `vm.bytes` via `OP_LOAD/STORE_FIELD`.
3. **Delete Value-slot `memory`/`immortal` arrays for aggregates** — ✅ value arrays are `.array` in `vm.bytes`; Value-slot heap remains for errors / arena control.
4. **Storage widths** — ✅ full matrix `i8`…`i64`, `u8`…`u64`, `f32`/`f64` + `@as`.
5. **Slice views** — ✅ `arr[i..j]` on packed bytes / strings (`OP_SLICE`).

## Non-goals

- JIT / tracing / LLVM AOT
- NaN-boxing (optional later micro-opt)
- Implicit numeric widen/narrow
- Lying types (annotate `u8` but execute as `i64`)

## Relation to language P6

Packed layout and widths are done. `*T` / `?*T` type IR landed (`@new` → `*Struct`). Remaining: address-of (`&x`), method `self: *T`, slice polish, enum payloads — see `TODO.MD` §P6.
