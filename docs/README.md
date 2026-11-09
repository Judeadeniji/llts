# LLTS Documentation

Welcome to the documentation for LLTS — a small systems language with a compact type system, Zig-inspired explicit memory, and a hand-written compiler with bytecode and native backends.

## Contents

- [**Getting Started**](getting-started.md)  
  Toolchain prerequisites, building from source, writing your first program, running on the VM vs compiling to a native binary, and editor configuration.

- [**Language Tour**](tour.md)  
  A fast-paced walkthrough of LLTS features: bindings, honest widths, arrays/slices, control flow expressions, methods, memory model, errors, and metaprogramming.

- [**Syntax & Grammar Reference**](syntax-and-grammar.md)  
  Formal specification of source encoding, tokens, comments, the `$` sigil, keywords, literal formats, operator precedence (14 levels), and EBNF grammar.

- [**Type System Documentation**](types/README.md)  
  In-depth guide to the LLTS type system:
  - [Primitive Widths & Scalar Types](types/primitive-widths.md) (`i8`–`i64`, `u1`–`u64`, floats, `void`, `never`, `@as`)
  - [Compound & Structural Types](types/compound-types.md) (`[N]T`, `[]T`, `[A, B]`, `*T`, anonymous shapes)
  - [Algebraic Types & Flow Narrowing](types/algebraic-types.md) (`?T`, `A | B`, `A & B`, flow typing, unwrap operators)
  - [User-Defined Types](types/user-defined.md) (`@struct`, `@enum`, `@error`, `@type`, `@alias`)

- [**Control Flow**](control-flow.md)  
  Comprehensive guide to statements and expressions: `@if` (value-producing, captures), `@switch` pattern matching, labeled switch continue (`continue :lbl`), `@for` (range, condition, iter), labels, and `break`/`continue`/`return`.

- [**Functions & Methods**](functions.md)  
  Function declarations (`@func`), entry point (`pub @func main`), parameter conventions, variadics (`...args`), struct methods with value and pointer receivers (`self` vs `self: *T`), first-class function values, the pipe operator (`|>`), and compile-time type functions.

- [**Error Handling**](error-handling.md)  
  Explicit, typed error values: closed error sets (`@error`), dynamic errors (`error("...")`), error unions (`T | Error`), try propagation (`?`), assertion unwrap (`.?`), runtime checks (`@isError`), exhaustive matching (`@switch`), and cleanup with `errdefer`.

- [**Memory Model & Safety**](memory-and-safety.md)  
  Frame-local region memory allocation, compile-time escape analysis preventing dangling frame references, auto-cloning scalar structs, deterministic scope cleanups (`defer` and `errdefer`), and pointer rules (`*T`, `&`).

- [**Metaprogramming & Compile-Time Evaluation**](metaprogramming.md)  
  Compile-time type reflection (`@typeOf`, `@sizeOf`, `@nameOf`), explicit casting (`@as`), generic type functions (`@func Opt(T: type): type`), generic functions with monomorphization, and constant evaluation via `@comptime`.

- [**Compiler Intrinsics**](intrinsics.md)  
  Exhaustive reference of all `@`-prefixed builtins: `@import`, `@asm`, `@as`, `@typeOf`, `@sizeOf`, `@nameOf`, `@isError`, `@addrOf`, `@concat`, `@extern`, and legacy `@new`.

- [**Modules & Organization**](modules.md)  
  Multi-file project architecture, relative module resolution via `@import`, the `pub` visibility modifier, imported types/methods, circular dependency detection, and diagnostic import stacks.

- [**Tooling & CLI Reference**](tooling-and-cli.md)  
  Complete manual for the `llts` command-line tool (`run`, `build`, `emit-zig`, `dump`), compiler flags (`--native`, `--strict`, `-O`, `--target`, `--emit`), the `llts-lsp` language server, and the `tree-sitter-llts` grammar.

- [**Language Reference**](language-reference.md)  
  Core language guide covering declarations, control flow, operators, types, frame-local memory semantics, typed error handling, and modules.

- [**Inline Assembly Guide**](inline-assembly.md)  
  Reference for the `@asm` intrinsic in the native backend, including constraints, clobbers, register operands, and verified Linux x86-64 examples.
