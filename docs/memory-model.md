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

Struct / value-array layout today: **one `Value` slot per field** → `@sizeOf` ≈ `field_count * 16` (see `src/compiler/intrinsics.zig`). That is a slot footprint, not machine layout.

Relevant code: `src/vm/state.zig`, `src/vm/execute/heap.zig`, `src/vm/builtins/mem.zig`.

### Packed byte policy (step 1 — done)

- `allocImmortalBytes` / `appendImmortal` / string builders raise `bytes_immortal_floor`.
- `allocFrameBytes` bumps `bytes_ptr` only; `CallFrame.bytes_watermark` + `rewindPacked` on return reclaim frame bytes down to the immortal floor.
- Strings and `[]byte` share `vm.bytes` (no separate `string_bytes` arena).

## Problems

1. Uniform `Value` slots waste memory and cache on aggregates.
2. `@sizeOf` / arenas cannot describe real layout.
3. Extra numeric widths (`u8`, `u16`, …) cannot pay off if everything is still a tagged slot.
4. Value-slot `memory` / `immortal` still parallel the packed byte region for structs/arrays.

## Target model

```
┌─────────────────────────────┐
│ Stack / globals / locals    │  tagged Value (honest types)
│  int = i64, float = f64     │  (+ ptr / slice handles)
│  later: real u8/u16/… tags  │
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

### Stack numerics (today / Track A)

Only `Value.int` (`i64`) and `Value.float` (`f64`) exist as numeric types — and that is honest. Language aliases that lie (e.g. `i32` → `int`) are separate debt.

### When widths land (Track B step 4)

Adding `u8` means typechecker + bytecode/ops + runtime value/layout all know `u8`. Representation may use a compact `Value` tag or typed load/store into the packed heap, but it must remain a true `u8`, not a disguised `i64`.

Example:

```llts
$b: u8 = buf[i];           # stays u8 at runtime
$n: int = @as(int, b);     # only widen
# $n = b;                  # illegal once widths exist
```

## Migration order

1. **Packed region beside old heaps** — ✅ unified `vm.bytes` for strings + `[]byte`; frame watermark + immortal floor.
2. **Struct fields as byte layout** — field offsets; change `@sizeOf` to real byte sizes (document alignment: start with align(8) for i64/f64/ptr, align(1) for u8).
3. **Delete Value-slot `memory`/`immortal` arrays for aggregates** — `Value.ptr` becomes a byte offset into the packed heap.
4. **Storage widths** — first-class `u8`/`u16`/… with explicit casts only.

## Non-goals

- JIT / tracing / LLVM AOT
- NaN-boxing (optional later micro-opt)
- Implicit numeric widen/narrow
- Lying types (annotate `u8` but execute as `i64`)
- Multi-width tags without packed layout

## Relation to language P6

This RFC is the substrate for pointers, slices, honest `@sizeOf`, and real widths listed under language roadmap P6. Do not add widths before steps 1–3.
