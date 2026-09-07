# List Module (`std/list.lls`)

Arena-backed growable lists. Element storage lives in the arena bump and is
reclaimed by `arena.reset()` / `arena.deinit()`. The list handle is **invalid**
after the arena is reset; ops then fail at runtime.

## Functions

### `create(arena)`
Creates an empty list whose storage is allocated in `arena`.

```llts
@const $list = @import("std/list");
@const $mem = @import("std/mem");
$a = mem.create(0);
$my_list = list.create(a);
```

### `createImmortal()`
Process-lifetime escape hatch: storage is never reclaimed by any arena.
Prefer `create(arena)`. Intended for std/fs and std/io return values that must
outlive a scratch arena — not for general application data.

### `push` / `pop` / `get` / `set` / `len`
Same shapes as before. Index out of bounds → `IndexOutOfBounds`.
Use after `arena.reset()` / `deinit()` → runtime error.
