# Error Handling Components (`/src/errors/`)

This document outlines the error reporting and stack trace formatting capabilities of the `llts-zig` runtime, optimized for agentic integration, understanding data flow, and debugging context.

## Overview

The `src/errors` module is responsible for formatting, logging, and dispatching diagnostic information. It is heavily inspired by TypeScript's error reporting style (e.g. `Error: message` and `--> path:line:col`). The module separates the concerns of visual output (source printing, stack traces) from the VM execution logic.

## Components and API

### 1. `report.zig`
Handles the visual formatting of diagnostics and source context.

- **`reportSourceError(path: []const u8, source: []const u8, line: u32, column: u32, message: []const u8) void`**
  - **Purpose**: Prints an inline code snippet with a caret (`^`) pointing to the specific error column, matching typical TS diagnostic formatting.
  - **Behavior**: Scans `source` linearly to find the exact `line` (1-indexed). Note that scanning linearly is `O(N)`, which is acceptable for error/crash paths but should be avoided in hot loops.
  
- **`reportLocationFrame(path: []const u8, line: u32, name: []const u8) void`**
  - **Purpose**: Prints a single stack frame entry in the format `    at name (path:line)`.

- **`reportCompileMessage(message: []const u8) void`**
  - **Purpose**: A simplified error printer used primarily for compilation/parsing errors before VM execution.

### 2. `stack_trace.zig`
Handles unwinding and formatting the VM's call stack.

- **`formatVmStackTrace(frames: []const state_mod.CallFrame, file: []const u8, line: u32) void`**
  - **Purpose**: Iterates over an array of `CallFrame`s backwards (from top of stack down to `<script>`).
  - **Constraint**: Uses the active `line` argument for the topmost (crashing) frame, but falls back to `f.line` (the invocation line) for caller frames further down the stack.

- **`reportStackTrace(frames: []const state_mod.CallFrame, file: []const u8, line: u32) void`**
  - Alias/wrapper for `formatVmStackTrace`.

### 3. `runtime.zig`
The primary entry point for triggering VM execution failures.

- **`runtimeFail(vm: *state_mod.VMState, message: []const u8) error{RuntimeError}`**
  - **Purpose**: Emits a complete diagnostic log (source snippet + stack trace) and returns `error.RuntimeError` to abort VM execution.
  - **Data Flow**:
    1. Extracts `vm.chunk.file`, `vm.chunk.source`, and `vm.current_line`. 
    2. Fallbacks: Uses `"<anonymous>"` if file is empty, and `1` if line is `0`.
    3. Calls `reportSourceError` for the main diagnostic.
    4. Calls `reportStackTrace` passing `vm.frames.items`.
    5. Returns Zig error `error.RuntimeError`.

## Dependencies and Struct Context

The error module relies heavily on VM state representations from `src/vm/state.zig` to populate trace logs.

```zig
// Required Context from `vm/state.zig`

pub const CallFrame = struct {
    func_name: []const u8 = "<script>",
    line: u32 = 1,
    // ... other VM fields
};

pub const VMState = struct {
    chunk: *Chunk,           // Provides .file and .source for diagnostics
    current_line: u32 = 1,   // Active line at the point of failure
    frames: std.ArrayList(CallFrame), // The call stack
    // ...
};
```

## Constraints and Assumptions

- **1-Indexed Lines**: Error reporting assumes 1-based line numbers. Passing `0` for a line number may break the visual source printer.
- **Output Channel**: These modules perform direct logging via `std.debug.print` rather than buffering output to strings or structs. This means errors are printed immediately to `stderr` during execution and cannot currently be captured as string values in the host program context without intercepting stderr.
- **Column Tracking**: The VM currently does not track exact column numbers at runtime (`runtimeFail` hardcodes `1` for the column in `reportSourceError`), pointing the caret at the start of the failing line.
