# Map Module (`std/map.lls`)

Arena-backed string-key map. Storage is reclaimed with `arena.reset()` /
`deinit()`. The map handle is invalid afterward; ops then fail at runtime.

```llts
@const $map = @import("std/map");
@const $mem = @import("std/mem");
$a = mem.create(0);
$m = map.create(a);
map.set(m, "k", 1);
print(map.get(m, "k"));
```

API: `create(arena)`, `set`, `get`, `has`, `delete`, `size`.
