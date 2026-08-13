# Error Handling Components (`/src/errors/`)

This document outlines the error reporting and stack trace formatting capabilities of the `llts-zig` runtime, optimized for agentic integration, understanding data flow, and debugging context.

## Overview

The `src/errors` module is responsible for formatting, logging, and dispatching diagnostic information. It is heavily inspired by TypeScript's error reporting style (e.g. `Error: message` and `--> path:line:col`). The module separates the concerns of visual output (source printing, stack traces) from the VM execution logic.

## Components and API

### 1. `report.zig`
Handles the visual formatting of diagnostics and source context.

- **`reportSourceError(path: []const u8, source: []const u8, line: u32, column: u32, message: []const u8) void`**
  - **Purpose**: Prints an inline code snippet with a caret (`^`) pointing to the specific error column, matching typical TS diagnostic formatting. Uses `io.out` and `io.color` for styled output.
  - **Behavior**: Scans `source` linearly to find the exact `line` (1-indexed). Note that scanning linearly is `O(N)`, which is acceptable for error/crash paths but should be avoided in hot loops.
  
- **`reportLocationFrameCol(path: []const u8, line: u32, column: u32, name: []const u8) void`**
  - **Purpose**: Prints a single stack frame entry in the format `    at name (path:line:col)`.

- **`reportCompileMessage(message: []const u8) void`**
  - **Purpose**: A simplified error printer used primarily for compilation/parsing errors before VM execution.

- **`diag.zig` Tracking**
  - **Purpose**: Uses `diag.markEmitted()` to track if a rich error was shown, preventing duplicate `Error:` lines in the CLI upon exit.

### 2. `stack_trace.zig`
Handles unwinding and formatting the VM's call stack.

- **`formatVmStackTrace(frames: []const state_mod.CallFrame) void`**
  - **Purpose**: Iterates over an array of `CallFrame`s backwards (from top of stack down to `<script>`). Extracts file, line, and column from each frame.

- **`reportStackTrace(frames: []const state_mod.CallFrame) void`**
  - Alias/wrapper for `formatVmStackTrace`.

### 3. `runtime.zig`
The primary entry point for triggering VM execution failures.

- **`runtimeFail(vm: *state_mod.VMState, message: []const u8) error{RuntimeError}`**
  - **Purpose**: Emits a complete diagnostic log (source snippet + stack trace) and returns `error.RuntimeError` to abort VM execution.
  - **Data Flow**:
    1. Extracts `file` from the topmost frame, falling back to `vm.chunk.file` or `"<anonymous>"`.
    2. Extracts `source` via `vm.sourceForFile(file)`. Uses `vm.current_line` and `vm.current_column` (falling back to `1` if `0`).
    3. Calls `reportSourceError` for the main diagnostic.
    4. Calls `reportStackTrace` passing `vm.frames.items`.
    5. Returns Zig error `error.RuntimeError`.

## Dependencies and Struct Context

The error module relies heavily on VM state representations from `src/vm/state.zig` to populate trace logs.

```zig
// Required Context from `vm/state.zig`

pub const CallFrame = struct {
    func_name: []const u8 = "<script>",
    file: []const u8 = "",
    line: u32 = 1,
    column: u32 = 1,
    // ... other VM fields
};

pub const VMState = struct {
    chunk: *Chunk,
    current_line: u32 = 1,
    current_column: u32 = 1,
    frames: std.ArrayList(CallFrame),
    // ...
};
```

## Constraints and Assumptions

- **1-Indexed Lines**: Error reporting assumes 1-based line numbers. Passing `0` for a line number or column will fallback to `1`.
- **Output Channel**: These modules perform direct logging via the custom `io` module (`io.out.printStderr`) rather than buffering output to strings or structs. This means errors are printed immediately to `stderr` during execution and cannot currently be captured as string values in the host program context without intercepting stderr.
- **Diagnostic State**: Diagnostic emissions are tracked globally in `diag.zig` (`emitted` flag). This allows the runtime and CLI to coordinate so they don't print redundant generic errors if a rich diagnostic was already rendered.
