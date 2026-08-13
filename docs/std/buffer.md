# Buffer Module (`std/buffer`)

The `buffer` module provides tools for working with contiguous arrays of bytes. Buffers are mutable and can dynamically resize when appending or resizing.

## Overview

Buffers in llts-zig can be manipulated as raw byte arrays, but also provide convenient methods for writing and reading strings, copying memory, and filling memory ranges. All byte values provided to functions like `set`, `push`, and `fill` are automatically masked to fit within 8 bits (i.e., `val & 0xFF`).

## Functions

### Creation & Allocation

#### `alloc(size)`
Allocates a new buffer of the specified `size` in bytes. All bytes are initialized to `0`.
- **Arguments**: 
  - `size` (Integer): The number of bytes to allocate.
- **Returns**: A new buffer.
- **Example**:
  ```javascript
  const buf = buffer.alloc(10); // Creates a buffer of 10 bytes initialized to 0
  ```

#### `create()`
Creates a new, empty buffer (size 0).
- **Returns**: A new empty buffer.
- **Example**:
  ```javascript
  const buf = buffer.create();
  ```

#### `fromString(str)`
Creates a new buffer containing the raw byte data of the provided string.
- **Arguments**:
  - `str` (String): The string to convert to a buffer.
- **Returns**: A new buffer.
- **Example**:
  ```javascript
  const buf = buffer.fromString("hello");
  ```

### Reading & Writing Data

#### `writeString(buf, offset, str)`
Writes a string into the buffer at the specified `offset`. The buffer must be large enough to accommodate the string.
- **Arguments**:
  - `buf` (Buffer): The destination buffer.
  - `offset` (Integer): The starting byte index.
  - `str` (String): The string to write.
- **Returns**: The number of bytes written.
- **Example**:
  ```javascript
  buffer.writeString(buf, 0, "world");
  ```

#### `appendString(buf, str)`
Appends a string to the end of the buffer, increasing the buffer's size.
- **Arguments**:
  - `buf` (Buffer): The destination buffer.
  - `str` (String): The string to append.
- **Returns**: The number of bytes appended.

#### `readString(buf, offset, len)`
Reads `len` bytes from the buffer starting at `offset` and returns them as a string.
- **Arguments**:
  - `buf` (Buffer): The source buffer.
  - `offset` (Integer): The starting byte index.
  - `len` (Integer): The number of bytes to read.
- **Returns**: A string containing the read bytes.

#### `get(buf, index)`
Gets the byte value (0-255) at the specified `index`.
- **Arguments**:
  - `buf` (Buffer): The buffer.
  - `index` (Integer): The byte index.
- **Returns**: The byte value at the index.

#### `set(buf, index, val)`
Sets the byte at the specified `index` to `val`. The value is masked with `0xFF`.
- **Arguments**:
  - `buf` (Buffer): The buffer.
  - `index` (Integer): The byte index.
  - `val` (Integer): The value to set (0-255).
- **Returns**: `null`.

#### `push(buf, val)`
Appends a single byte `val` to the end of the buffer. The value is masked with `0xFF`.
- **Arguments**:
  - `buf` (Buffer): The buffer.
  - `val` (Integer): The byte value to append (0-255).
- **Returns**: `null`.

### Memory Operations

#### `copy(dst, dst_off, src, src_off, len)`
Copies `len` bytes from the `src` buffer starting at `src_off` to the `dst` buffer starting at `dst_off`. Handles overlapping copies if `src` and `dst` are the same buffer.
- **Arguments**:
  - `dst` (Buffer): The destination buffer.
  - `dst_off` (Integer): The starting offset in the destination buffer.
  - `src` (Buffer): The source buffer.
  - `src_off` (Integer): The starting offset in the source buffer.
  - `len` (Integer): The number of bytes to copy.
- **Returns**: `null`.

#### `fill(buf, val)`
Fills the entire buffer with the specified byte `val` (masked with `0xFF`).
- **Arguments**:
  - `buf` (Buffer): The buffer.
  - `val` (Integer): The value to fill the buffer with.
- **Returns**: `null`.

#### `fillRange(buf, val, start, len)`
Fills `len` bytes of the buffer starting at the `start` index with the specified byte `val` (masked with `0xFF`).
- **Arguments**:
  - `buf` (Buffer): The buffer.
  - `val` (Integer): The value to fill with.
  - `start` (Integer): The starting byte index.
  - `len` (Integer): The number of bytes to fill.
- **Returns**: `null`.

### Utilities

#### `len(buf)`
Returns the length of the buffer in bytes.
- **Arguments**:
  - `buf` (Buffer): The buffer.
- **Returns**: The length of the buffer.

#### `resize(buf, new_len)`
Resizes the buffer to `new_len`. If the new length is greater than the current length, the additional bytes are initialized to `0`. If the new length is smaller, the buffer is truncated.
- **Arguments**:
  - `buf` (Buffer): The buffer to resize.
  - `new_len` (Integer): The new length.
- **Returns**: `null`.
