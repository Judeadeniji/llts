# LLTS Entry Points & Pipeline

## Overview
This document outlines the entry points, CLI arguments, initialization sequence, and compilation pipeline for the LLTS compiler/VM. It is structured to help agents quickly understand the execution flow from the CLI through to VM execution.

## CLI (`src/main.zig`)

The CLI is built with [zli](https://github.com/xcaeser/zli) and uses subcommands:

| Command | Description |
|---------|-------------|
| `llts run <file> [args...]` | Compile and run a `.lls` source file, or execute a precompiled `.llb` bytecode file directly. |
| `llts build <file> [-o out.llb]` | Compile a `.lls` source file to binary bytecode (default output: `out.llb`). |
| `llts dump <file> [-o FILE]` | Compile a `.lls` source and write a human-readable bytecode dump to stdout or `FILE`. |
| `llts smoke` | Run a hardcoded VM smoke test (`print(42)`) without reading any file. |

Global flags (available on all subcommands):

- `-r, --release`: Disables debug mode in the compiler/VM. When provided, `RunOptions.debug` evaluates to `false`. Default is `true`.
- `--log-level <LEVEL>`: Sets the minimum log level for the IO subsystem (e.g., `trace`, `debug`, `info`, `warn`, `err`).

Program arguments: trailing positionals after the source path are forwarded as `os.args()[1..]`. `os.args()[0]` is always the source path.

Examples:

```sh
llts run examples/hello-world.lls
llts run program.lls hello world
llts run program.lls -- -r   # "-r" is a program arg, not a host flag
llts build app.lls -o app.llb
llts dump app.lls -o dump.txt
llts smoke
llts --help
```

## Initialization Sequence

1. **Subsystem Initialization:** The custom IO, logging, and color systems are initialized (e.g., `initFromEnv()`). Zig's default `std.log` is wired to the new custom `io.log` subsystem via `std_options`.
2. **Allocator Setup:** A `std.heap.GeneralPurposeAllocator` is initialized and used for the entire program lifecycle.
3. **Argument Parsing:** zli parses subcommands, flags, and positional arguments.
4. **Pre-Execution Setup:** The target file is fully read into memory using `std.fs.cwd().readFileAlloc` (up to a max size of 16MB). The `llts.diag` API state is reset for the new execution.
5. **Execution Delegation:** Passes the source string and options to `llts.runSource` (exposed via `src/root.zig`), which delegates to `pipeline.runSource`.

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
- **Entry point:** The root file must define `pub @func main()` with no parameters. Missing `main`, a private `main`, or a `main` with parameters is a compile error. Top-level statements run first as module init, then `main` is called.
- **Tree shaking:** After typechecking, a reachability pass emits only functions and module-level initializers referenced from the entry file (plus transitive callees and globals). Importing `std/index` still parses the full stdlib, but unreached functions are omitted from the chunk.

### 4. VM & Execution Phase
- **State Initialization:** `VMState.init()` sets up the VM given the `Chunk`.
- **Module Resolution Prep:** `state.script_path` is initialized to support module resolution.
- **Builtins Registration:** `builtins.registerBuiltins(&state)` initializes global/native functions in the VM state.
- **Execution:** `execute.execute(&state, 0)` begins bytecode interpretation starting at instruction pointer `0`. Errors emitted during runtime are captured and handled by the `diag` API.

## Public API (`src/root.zig`)

`root.zig` serves as the primary export namespace for the `llts` package. It exports core components, making them accessible to `main.zig` and other consumers:
- **Core Types:** `OpCode`, `Value`, `Chunk`, `VMState`, `Document`, `RunOptions`
- **Subsystems:** Exports the `io` (logging, colors, formatting) and `diag` (error and diagnostic reporting) APIs.
- **Bytecode tools:** `disasm.dump` writes a human-readable chunk listing (constants, functions, instructions). `serialize.read` / `serialize.write` load and save lean binary `.llb` artifacts.
- **Execution Endpoints:** 
  - `compileSource`: Scan, parse, and compile without running.
  - `writeBytecodeFile` / `readBytecodeFile`: Save and load binary bytecode.
  - `runBytecodeFile`: Load `.llb` and execute (CO-RE).
  - `runSource`: The standard pipeline execution.
  - `runChunk`: Useful for running pre-built/manually constructed chunks directly (e.g., used by the `smoke` subcommand).
