# LLTS Entry Points & Pipeline

## Overview
This document outlines the entry points, CLI arguments, initialization sequence, and compilation pipeline for the LLTS compiler/VM. It is structured to help agents quickly understand the execution flow from the CLI through to VM execution.

## CLI Arguments (`src/main.zig`)

The CLI entry point `main()` parses the following arguments:

- `-i, --input <file.lls>`: **(Required unless `--smoke` is provided)** Specifies the path to the input LLTS file to execute.
- `-r, --release`: Disables debug mode in the compiler/VM. When provided, `RunOptions.debug` evaluates to `false`. Default is `true`.
- `--smoke`: Runs a hardcoded VM smoke test (`print(42)`) manually constructing a bytecode chunk, running it, and exiting immediately without reading any file.

## Initialization Sequence

1. **Allocator Setup:** A `std.heap.GeneralPurposeAllocator` is initialized and used for the entire program lifecycle.
2. **Argument Parsing:** CLI arguments are parsed to determine the input file and execution mode (debug/release).
3. **Source Loading:** The target file is fully read into memory using `std.fs.cwd().readFileAlloc` (up to a max size of 16MB).
4. **Execution Delegation:** Passes the source string and options to `llts.runSource` (exposed via `src/root.zig`), which delegates to `pipeline.runSource`.

## Compilation Pipeline (`src/pipeline.zig`)

The pipeline orchestrated by `runSource` runs sequentially, transforming raw source code into VM execution. The steps are strictly ordered, where each phase consumes the output of the prior one:

### 1. Scanner Phase (`scanner.scan`)
- **Input:** Source text (`[]const u8`), file path.
- **Output:** `scan_result` containing a linear list of `Token` items.

### 2. Parser Phase (`parser.parse`)
- **Input:** Token list, file path, source text.
- **Output:** `Document` containing the Abstract Syntax Tree (AST).

### 3. Compiler Phase (`compiler.compile`)
- **Input:** AST `Document`, Compiler Options (containing `debug` boolean).
- **Output:** Bytecode `Chunk`.

### 4. VM & Execution Phase
- **State Initialization:** `VMState.init()` sets up the VM given the `Chunk`.
- **Builtins Registration:** `builtins.registerBuiltins(&state)` initializes global/native functions in the VM state.
- **Execution:** `execute.execute(&state, 0)` begins bytecode interpretation starting at instruction pointer `0`.

## Public API (`src/root.zig`)

`root.zig` serves as the primary export namespace for the `llts` package. It exports core components, making them accessible to `main.zig` and other consumers:
- **Core Types:** `OpCode`, `Value`, `Chunk`, `VMState`, `Document`, `RunOptions`
- **Execution Endpoints:** 
  - `runSource`: The standard pipeline execution.
  - `runChunk`: Useful for running pre-built/manually constructed chunks directly (e.g., used by the `--smoke` flag).
