# LLTS Compiler Architecture

This document outlines the internal architecture, state management, and code generation strategies of the LLTS compiler phase (`src/compiler`). The compiler's primary responsibility is translating an Abstract Syntax Tree (AST) into executable Bytecode (Chunks).

## Overview

The compilation pipeline takes a parsed `ast.Document` and produces a single, cohesive `Chunk` of bytecode. The compiler relies on a multi-pass approach to handle out-of-order declarations, module imports, and gradual typechecking before emitting any bytecode.

### Compilation Phases

The `compile()` function in `root.zig` orchestrates the following passes:

1. **Module Resolution (`modules.zig`)**: 
   - Recursively resolves `@import` statements.
   - Loads, tokenizes, and parses imported files.
   - Inlines imported AST nodes into the root document while mangling names (e.g., `ModName::StructName`) to prevent symbol collisions.
2. **Registration Pass**:
   - Scans the document to register structs, enums, globals, and constants.
   - Computes function metadata (arity, variadic flags, return types, call graphs to detect recursion).
3. **Typechecking (`typecheck/root.zig`)**:
   - A gradual typechecker that walks the AST.
   - Validates struct initialization, function call arguments, assignability, and arithmetic operations.
   - Enforces known types while falling back to `TUnknown` for untyped values.
4. **Code Generation**:
   - Compiles functions (assigning function addresses and patching forward references).
   - Emits bytecode for top-level statements.
   - Generates an entry point that requires a zero-arity `main()` and calls it after top-level statements.

## State Management (`CompilerState`)

The entire compilation process shares a mutable `CompilerState` (`state.zig`), which manages lexical scoping, symbols, and bytecode buffers.

### Key State Components

- **Locals Array (`std.ArrayList(Local)`)**: Tracks variables in the current lexical scope. Each local tracks its string name, lexical depth, mutability (`is_const`), and allocation region (for escape analysis).
- **Scope Tracking (`scope_depth: i32`)**: Incremented when entering a block and decremented when leaving. Used to map locals to their visibility and lifetime.
- **Defer Stacks (`defer_stacks`)**: Maps a scope depth to a list of deferred AST nodes. These nodes are stored during traversal and compiled immediately before the scope exits.
- **Control Flow Trackers (`loops`, `exprs`)**: Stacks that track metadata for loops and block expressions to facilitate correct `break` and `continue` jump offsets.
- **Symbol Tables**: Maps strings to rich metadata definitions (`functions`, `structs`, `enums`, `global_vars`).
- **Diagnostics State (`diag_path`, `diag_line`, `diag_column`)**: Tracks the physical source location of the AST node currently being compiled or typechecked. This state is fed into the `src/errors/` subsystem to produce rich, contextual compile errors.

## Code Generation Strategy

The LLTS compiler is a single-pass bytecode emitter *after* the initial metadata and typechecking passes. Code generation heavily utilizes utilities in `emit.zig` and `scope.zig`.

### Chunk and Bytecode Emission
- **Direct Emission**: Bytecode is written directly to an active `Chunk` (which owns a `std.ArrayList(u8)`).
- **Constant Pool**: Strings and numbers are inserted into the chunk's constant table. The emitter outputs `OP_CONSTANT` followed by a 16-bit index to the constant pool.
- **Variables**:
  - **Locals**: Addressed by their index on the execution stack. The compiler uses `resolveLocal` to map a variable name to a stack slot and emits `OP_GET_LOCAL <slot>`.
  - **Globals**: Resolved dynamically at runtime. The compiler emits `OP_GET_GLOBAL <string_idx>`, fetching the global's name from the constant pool.

### Jump Patching
For forward jumps (like `if`, `while`, or jumping over function bodies), the compiler emits a placeholder offset (`0xFFFF`) using `emitJump`. Once the target destination's address is known, `patchJump` rewrites the actual distance into the placeholder bytes.

### Scope and Cleanup
The compiler uses an implicit stack machine. When a scope ends (`endScope` in `scope.zig`):
1. **Defers**: `emitScopeDefers` compiles all `defer` statements registered for the current depth.
2. **Pops**: `emitPopsAtDepth` emits `OP_POP` instructions to discard local variables that are going out of scope, keeping the runtime stack clean.

## Diagnostics and IO

The compiler and VM utilize dedicated subsystems for reporting and logging:
- **Errors (`src/errors/`)**: A rich diagnostic API that formats and prints context-aware error messages. It uses the `diag_path`, `diag_line`, and `diag_column` from the compiler state (or instruction pointer during runtime) to point directly to the offending source code. It includes components like `report.zig` for formatting and `stack_trace.zig` for VM panics.
- **Logging and Output (`src/io/`)**: Replaces standard `std.debug.print` with robust posix-level logging (`io.printStderr`, `io.printStdout`). It supports ansi-colored log levels (`trace`, `debug`, `info`, `warn`, `err`) driven by the `LLTS_LOG_LEVEL` environment variable.

## Input / Output

- **Input**: The compiler takes an initialized `std.mem.Allocator`, a root `*ast.Document`, and `CompileOptions` (e.g., debug flags).
- **Output**: A fully baked `chunk_mod.Chunk` object. The chunk contains the executable instructions, the constant pool, inline function metadata, and debug line mappings.
- **Ownership**: The caller is responsible for the returned `Chunk`. The `CompilerState` ensures that temporary allocations (like parsed module ASTs and type strings) are cleaned up via `state.deinit()` before returning the chunk.
