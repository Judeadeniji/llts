## 1. What MUST Be in the Core Language

These are the primitive building blocks. The compiler must understand these intrinsically because they map directly to CPU instructions, memory layouts, or execution flow control. [2, 3]

* Primitive Types: Booleans, signed/unsigned integers, floating-point numbers, and pointers.
* Flow Control: Branching (if/else), looping (while/for), and jumping (return, break).
* Memory Layout Mechanics: Structural declarations (struct, class, or enums) and basic stack allocation.
* Basic Operators: Arithmetic (+, -, *, /), bitwise transformations (<<, &, |), and assignment (=).
* Function Invocation: The calling convention mechanism (how variables are pushed onto the stack and how execution jumps to a new memory address). [4, 5, 6, 7, 8]

## 2. What SHOULD Be in the Standard Library

These are features built using the core language components. The compiler does not need to know how these work; it just treats them as code written by a developer. [9, 10, 11]

* Dynamic Collections: Vectors, Resizable Arrays, HashMaps, and Linked Lists.
* Data Parsing: Converting strings to numbers (like atoi), text formatting, and regex processing.
* Mathematical Operations: Higher-level math functions like sin(), cos(), sqrt(), and random number generators.
* Time & Date Tracking: Structs for measuring epoch time, formatting timestamps, and handling timezones. [12, 13, 14, 15]

## 3. The "Gray Area" (Compiler Intrinsics)

This is where language design gets tricky. Some features look like standard library functions to the developer, but they require compiler intrinsics (special hooks) because they need low-level OS access, magic memory access, or type metadata. [16, 17]

* Memory Management (malloc / free / new): The language needs a syntax hook or a runtime engine to request heap pages from the OS. In C, malloc is a library function calling an OS hook. In Go/Java, memory allocation is part of the core language runtime (Garbage Collector). [18, 19, 20, 21, 22]
* Input/Output (print / read): In Python, print() is a core built-in function. In C, printf() is a library function wrapping a syscall. Deciding which path to take depends on how fundamental you want console I/O to be. [23, 24, 25, 26, 27]
* Reflection / Type Inspection: If your language allows checking a type at runtime (e.g., typeof(x)), the compiler must inject metadata into the compiled binary. This requires a bridge where the library reads core compiler structures. [28, 29]
