# Buffer Module (`std/buffer.lls`)

Arena-backed growable byte buffer. Prefer `create(arena)` / `alloc(arena, n)` /
`fromString(arena, s)`. Storage is reclaimed with `arena.reset()` / `deinit()`;
the handle is invalid afterward.

`createImmortal()` is a process-lifetime escape hatch for fs/io return values
that must outlive a scratch arena. Prefer a caller-owned arena when possible.

```llts
@const $buffer = @import("std/buffer");
@const $mem = @import("std/mem");
$a = mem.create(0);
$b = buffer.create(a);
buffer.appendString(b, "hi");
```
