# Inline Assembly in LLTS

Native builds support target-specific, side-effecting assembly with the `@asm` intrinsic.

> **Note:** The bytecode backend rejects `@asm`, as it is a native-only intrinsic.

## Basic Syntax

Native code may embed target-specific, side-effecting assembly with `@asm("template")`. The template must be a string literal. Use a fenced multiline string for multi-instruction templates:

```lls
@asm(```
    nop
    nop
```);
```

## Extended Assembly

Extended assembly uses GNU-style template, output, input, and clobber sections:

```lls
@asm(ReturnType, ```<template> : <outputs> : <inputs> : <clobbers>```)
```

`${expression}` holes bind LLTS values without string formatting or runtime assembly building:

```lls
$sum = @asm(i64, ```
    movq %[left], %[result]
    addq %[right], %[result]
    : [result] "=&r" (-> i64)
    : [left] "r" (${left}),
      [right] "r" (${right})
    : "cc", "memory"
```);
```

## Operands, Constraints, and Clobbers

* **Literal Registers vs Operands:** Write literal CPU registers with doubled percent signs (e.g. `%%rax`, `%%rdi`), and reference named inputs/outputs as `%[name]`.
* **Constraints:**
  * `"r"`: General-purpose register input.
  * `"=r"` / `"=&r"`: Output register (`&` denotes early-clobber to prevent sharing with inputs).
  * `"+r"`: Read-modify-write in-place operand on a mutable place (e.g. `[x] "+r" (${x})`).
  * `"{reg}"`: Specific hardware register constraint (e.g. `"{rax}"`, `"{rdi}"`, `"{rsi}"`).
* **Clobbers:** List clobbered registers and effects in the 4th section (e.g. `"cc"` for condition flags, `"memory"` for memory barriers, or clobbered registers like `"rcx"`, `"r11"`).
* **Rules & Limits:**
  * Operands must fit within CPU register sizes (at most 8 bytes on 64-bit targets). Aggregates and slices (`[]byte`, which are 16-byte structs) cannot be passed directly into registers.
  * To pass a memory buffer, declare a fixed-size byte array and pass its pointer using `&` (e.g. `$buf: [3]u8 = [72, 105, 10]; $p = &buf;`).
  * Operand values must be written as `${expr}` holes. To pass an immediate constant into a register, bind it to a local variable first (e.g. `$nr: i64 = 1;` then `(${nr})`).
  * `asm goto` is not supported.

## Verified Linux x86-64 Examples

### 1. Exit with status 42 (`sys_exit` = 60)

```lls
pub @func main() {
    @asm(```
        movq $60, %%rax
        movq $42, %%rdi
        syscall
    ```);
}
```

### 2. In-place update (`+r` operand)

```lls
pub @func main() {
    $x: i64 = 21;
    @asm(void, ```
        addq %[x], %[x]
        : [x] "+r" (${x})
        :
        : "cc"
    ```);
    print(x); // 42
}
```

### 3. Linux x86-64 `write` syscall with buffer pointer (`sys_write` = 1)

Syscall calling convention on Linux x86-64 uses `rax` for the syscall number, `rdi`, `rsi`, `rdx` for arguments 1-3, and clobbers `rcx` and `r11`:

```lls
pub @func main() {
    $buf: [3]u8 = [72, 105, 10]; // 'H', 'i', '\n'
    $p = &buf;
    $nr: i64 = 1;
    $fd: i64 = 1;
    $n: i64 = 3;
    $r = @asm(i64, ```
        syscall
        : [ret] "={rax}" (-> i64)
        : [nr] "{rax}" (${nr}),
          [fd] "{rdi}" (${fd}),
          [buf] "{rsi}" (${p}),
          [cnt] "{rdx}" (${n})
        : "rcx", "r11", "memory"
    ```);
    print("bytes written:", r);
}
```
