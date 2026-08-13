# std/mem

The `std/mem` module provides essential utilities for dynamic memory allocation. This module operates as part of the standard library but interfaces closely with the VM's built-in memory management intrinsic hooks.

## Overview

In `llts-zig`, the memory region model supports different styles of allocation:
- **Frame-Local Bump Allocation:** Creating simple objects or arrays directly (e.g., `Foo{}` or `[...]`) typically performs a frame-local bump allocation. These objects die when the function returns and cannot safely escape.
- **Heap/Library Allocation:** Using `alloc` or an `Arena` allocator pushes items to the heap, which allows objects to outlive their current frame.

## Functions

### `alloc`
```zig
pub @func alloc(size)
```
Performs a direct low-level allocation on the VM heap.

- **Parameters:**
  - `size` (int): The number of slots to allocate.
- **Returns:** A pointer to the newly allocated memory.
- **Note:** This function directly maps to the `__alloc` VM intrinsic.

### `create`
```zig
pub @func create(initial_hint): Arena
```
Creates and initializes a new growable `Arena` allocator. 

The `Arena` is a bump-pointer allocator that allocates objects contiguously in chunks. When the current chunk fills up, a new, larger chunk (growing by approximately 1.5×) is created and appended to the chunk list.

- **Parameters:**
  - `initial_hint` (int): The initial data slot capacity of the first chunk. Passing `0` will select a reasonable default size (e.g., 64 slots). This acts as a hint and is not a hard cap on the total capacity the arena can manage.
- **Returns:** An initialized `Arena` instance.

## Types

### `Arena`
```zig
pub @struct Arena {
    handle: int;
}
```
A growable bump-pointer allocator designed to manage memory in regions. You can allocate multiple objects within the arena and clear them all at once by resetting or deinitializing the arena.

#### Methods

##### `alloc`
```zig
@func alloc(self, n)
```
Allocates memory for `n` slots from the arena.
- **Parameters:**
  - `n` (int): The number of slots to allocate.
- **Returns:** A pointer to the allocated memory.

##### `reset`
```zig
@func reset(self)
```
Resets the arena's memory usage without returning the underlying chunk memory to the system (analogous to Zig's `retain_capacity` behavior). It rewinds the internal watermarks of all chunks to their base, allowing future allocations to reuse the previously requested chunks efficiently.

##### `deinit`
```zig
@func deinit(self)
```
Marks the arena as deinitialized. Subsequent calls to allocate from or reset this arena will result in a runtime error.

## Examples

### Using the Arena Allocator

```zig
const mem = @import("std/mem.lls");

pub @func main() {
    # Create a new arena with a default initial chunk size
    const arena = mem.create(0);
    
    # Allocate items in the arena
    const data = arena.alloc(10);
    const more_data = arena.alloc(20);
    
    # Fast reuse of the memory chunks (watermarks are rewound)
    arena.reset();
    
    # Subsequent allocations will reuse the retained capacity
    const new_data = arena.alloc(15);
    
    # Clean up when entirely done
    arena.deinit();
}
```
