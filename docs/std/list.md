# List Module (`std/list.lls`)

The `list` module provides standard operations for creating and manipulating dynamic arrays (lists) in `llts`. It acts as a wrapper around the native virtual machine list operations.

## Functions

### `create()`
Creates and returns a new empty list.

**Returns:**
- A new `list` object.

**Example:**
```llts
let my_list = list.create();
```

### `push(lst, item)`
Appends an `item` to the end of the list.

**Parameters:**
- `lst`: The list to modify. Must be a `list`.
- `item`: The value to append. Can be of any type.

**Returns:**
- The modified `list`.

**Errors:**
- Throws `TypeError` if `lst` is not a list.

**Example:**
```llts
list.push(my_list, 42);
list.push(my_list, "hello");
```

### `pop(lst)`
Removes and returns the last element of the list.

**Parameters:**
- `lst`: The list to pop from. Must be a `list`.

**Returns:**
- The removed element, or `null` if the list is empty.

**Errors:**
- Throws `TypeError` if `lst` is not a list.

**Example:**
```llts
let last_item = list.pop(my_list);
```

### `get(lst, index)`
Retrieves the element at the specified `index`.

**Parameters:**
- `lst`: The list to access. Must be a `list`.
- `index`: The zero-based integer index of the element. Must be an `int`.

**Returns:**
- The value at the given `index`.

**Errors:**
- Throws `TypeError` if `lst` is not a list or `index` is not an int.
- Throws `IndexOutOfBounds` if `index` is greater than or equal to the length of the list.

**Example:**
```llts
let first_item = list.get(my_list, 0);
```

### `set(lst, index, item)`
Replaces the element at the specified `index` with a new `item`.

**Parameters:**
- `lst`: The list to modify. Must be a `list`.
- `index`: The zero-based integer index of the element to replace. Must be an `int`.
- `item`: The new value to set. Can be of any type.

**Returns:**
- The newly set `item`.

**Errors:**
- Throws `TypeError` if `lst` is not a list or `index` is not an int.
- Throws `IndexOutOfBounds` if `index` is greater than or equal to the length of the list.

**Example:**
```llts
list.set(my_list, 0, "new value");
```

### `len(lst)`
Returns the number of elements in the list.

**Parameters:**
- `lst`: The list to measure. Must be a `list`.

**Returns:**
- An `int` representing the length of the list.

**Errors:**
- Throws `TypeError` if `lst` is not a list.

**Example:**
```llts
let size = list.len(my_list);
```
