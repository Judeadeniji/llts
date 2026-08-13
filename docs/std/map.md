# `std/map`

The `map` module in the standard library provides functions for creating and manipulating hash maps (dictionaries). A map stores key-value pairs, where keys are coerced to strings, and values can be of any type.

## Overview

Maps in `llts-zig` provide $O(1)$ average time complexity for insertions, deletions, and lookups.

To use the `map` module, import it first:

```js
const map = import("std/map");
```

## Functions

### `create()`

Creates and returns a new, empty map.

**Signature:**
```js
pub @func create()
```

**Returns:**
A new, empty map object.

**Example:**
```js
const map = import("std/map");

const my_map = map.create();
```

---

### `set(mp, key, value)`

Inserts a key-value pair into the map. If the key already exists, its value is updated. The key is automatically coerced to a string representation.

**Signature:**
```js
pub @func set(mp, key, value)
```

**Parameters:**
- `mp`: The map to modify.
- `key`: The key to set (will be converted to a string).
- `value`: The value to associate with the key (can be of any type).

**Returns:**
The `value` that was just set.

**Example:**
```js
const map = import("std/map");
const my_map = map.create();

map.set(my_map, "name", "Alice");
map.set(my_map, "age", 30);
map.set(my_map, 42, "the answer"); // Key 42 is coerced to string "42"
```

---

### `get(mp, key)`

Retrieves the value associated with the specified key in the map.

**Signature:**
```js
pub @func get(mp, key)
```

**Parameters:**
- `mp`: The map to query.
- `key`: The key to look up.

**Returns:**
The value associated with the key, or `null` if the key does not exist in the map.

**Example:**
```js
const map = import("std/map");
const my_map = map.create();
map.set(my_map, "name", "Alice");

const name = map.get(my_map, "name"); // Returns "Alice"
const missing = map.get(my_map, "city"); // Returns null
```

---

### `has(mp, key)`

Checks if the map contains the specified key.

**Signature:**
```js
pub @func has(mp, key)
```

**Parameters:**
- `mp`: The map to check.
- `key`: The key to check for.

**Returns:**
`true` if the map contains the key, `false` otherwise.

**Example:**
```js
const map = import("std/map");
const my_map = map.create();
map.set(my_map, "color", "red");

if (map.has(my_map, "color")) {
    // Key exists
}
```

---

### `delete(mp, key)`

Removes the specified key and its associated value from the map.

**Signature:**
```js
pub @func delete(mp, key)
```

**Parameters:**
- `mp`: The map to modify.
- `key`: The key to remove.

**Returns:**
`true` if the key was found and removed, `false` if the key did not exist in the map.

**Example:**
```js
const map = import("std/map");
const my_map = map.create();
map.set(my_map, "temporary", "data");

const was_deleted = map.delete(my_map, "temporary"); // Returns true
const deleted_again = map.delete(my_map, "temporary"); // Returns false
```

---

### `size(mp)`

Returns the number of key-value pairs stored in the map.

**Signature:**
```js
pub @func size(mp)
```

**Parameters:**
- `mp`: The map to query.

**Returns:**
An integer representing the number of entries in the map.

**Example:**
```js
const map = import("std/map");
const my_map = map.create();

map.set(my_map, "a", 1);
map.set(my_map, "b", 2);

const count = map.size(my_map); // Returns 2
```
