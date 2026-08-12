# llts Array Usage Documentation

This document provides a technical overview of arrays in the `llts` language, intended for agent reference.

## 1. Initialization and Syntax
- **Array Literals**: Arrays are created using square bracket syntax with comma-separated values.
  ```llts
  # Creates a length-prefixed array literal
  $arr = [0, 0, 0, 0, 0];
  ```
- **Type**: These literals are length-prefixed under the hood, making their size retrievable at runtime.

## 2. Indexing and Assignment
- **0-Based Indexing**: Elements are accessed and mutated using standard `array[index]` syntax.
  ```llts
  arr[0] = 42;
  arr[1] = 1337;
  
  # Accessing values
  std.debug.printLn("arr[0] = {i}", arr[0]);
  ```

## 3. Built-in Functions
- **`len()`**: Retrieves the length (bounds) of an array literal.
  ```llts
  std.debug.assert(len(arr) == 5);
  ```

## 4. Advanced / Low-Level Allocation
- **Raw Heap Allocation**: If you need raw heap memory without length-prefixing overhead, use `std.mem.alloc`.
  ```llts
  $raw = std.mem.alloc(3);
  std.debug.printLn("raw ptr = {i}", raw);
  ```
  *Note: `std.mem.alloc` returns a raw pointer rather than a standard array literal.*
