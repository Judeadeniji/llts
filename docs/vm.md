# Llts-Zig Virtual Machine

This document details the internal architecture of the Llts-Zig Virtual Machine, focusing on its runtime structures, memory model, and instruction dispatch loop. It is intended for agents and developers interacting with or extending the VM implementation.

## 1. Runtime Environment (`VMState`)

The virtual machine context is encapsulated entirely within `state.zig:VMState`. It provides the memory, stack, and globals required for execution.

Key components of `VMState`:
* **`stack`**: A unified `std.ArrayList(Value)` stack used for both instruction operands and local variables.
* **`frames`**: A stack of `CallFrame` objects (max depth: `MAX_FRAMES` = 256).
* **`memory`**: The object heap, a `[]Value` bump region (`MEMORY_SIZE` slots) for structs, `[]int` arrays, and errors.
* **`bytes`**: Packed byte heap (`BYTE_MEMORY_SIZE`) for `@new` `[]byte` / `[N]byte` buffers. One host byte per element.
* **`string_bytes`**: A zero-alloc, append-only `std.ArrayList(u8)` arena for dynamic string data.
* **`globals` / `modules`**: Hash maps that own and resolve global variables and module instances.

### Call Frames

A `CallFrame` (`state.zig`) tracks the execution context of a function. 
* `base_slot`: The absolute stack index where this function's arguments and local variables start.
* `return_ip`: The instruction pointer to restore on `OP_RETURN`.
* `arg_count`: The number of arguments passed to the function.
* `heap_watermark`: An `i32` index tracking the heap's boundary at the time the frame was pushed.

## 2. Value System & Stack Representation

The VM is dynamically typed at runtime, utilizing a tagged union (`value.zig:Value`) for all stack and heap elements:
* **Primitives**: `.null`, `.bool`, `.int` (i32), `.float` (f64).
* **Strings**: Represented as `.slice` (offset/len into `string_bytes arena`) or `.name` (interned constant index).
* **Packed bytes**: `.bytes { offset, len }` into `VMState.bytes` — mutable `@new` byte buffers. 
* **Pointers**: `.ptr` is a simple `i32` index pointing into the `VMState.memory` array.
* **Objects**: Functions (`.function`, `.native`) and Modules (`.module`).

All operations push/pop `Value` tags onto `VMState.stack`. Local variables are accessed directly via stack offsets relative to `CallFrame.base_slot` using `OP_GET_LOCAL` / `OP_SET_LOCAL`.

## 3. Heap Representation & Memory Management

The heap is a single, contiguous array (`vm.memory`) using a bump allocator managed by `vm.heap_ptr`. Allocation starts at `HEAP_START` (1024). It heavily leans on region-based lifetimes rather than tracing garbage collection.

### Region-Based Lifetimes
1. **Frame-Local (Implicit)**: Standard allocations (e.g., arrays, structs) call `vm.allocSlots()`, which bumps `heap_ptr`. When a function executes `OP_RETURN`, `vm.heap_ptr` is rewound to the frame's `heap_watermark`. This immediately reclaims all local allocations without overhead.
2. **Immortal (Escaping)**: Values meant to escape a function's scope (e.g., error objects) call `vm.allocImmortal()`. This allocation bumps the `heap_ptr`, but also updates the `heap_watermark` of *all active frames*. As a result, the rewind step in `OP_RETURN` will not destroy the escaping object.

### Object Metadata
Heap objects store their metadata immediately before their pointer index:
* **Arrays**: For an array at `ptr`, the length is stored as an `.int` at `ptr - 1`.
* **Errors**: For an error object at `ptr`, a distinct `.int` tag (`ERROR_TAG` = 0xE2202) is stored at `ptr - 1`, and the message value is placed at `ptr`.

## 4. Instruction Dispatch Loop

The primary execution loop is `execute(vm: *VMState, start_ip: usize)` inside `execute/root.zig`. 

* **The Loop**: It runs a standard `while (ip < code.len)` loop over the bytecode, switching on `OpCode` tags.
* **Watchdog Timer**: To prevent infinite loops or catastrophic hangs, the execution loop enforces a hard limit of `max_steps` (50,000,000 instructions) after which it throws a `RuntimeError`.
* **Operand Decoding**: Inline arguments are read using `readByte()` (u8) and `readShort()` (u16).
* **Execution Flow**:
  * Arithmetic & Comparisons: Dispatch to typed helpers in `arith.zig` and `compare.zig`.
  * Function Invocation: `OP_CALL_STATIC` executes directly if the address is known. `OP_CALL` handles dynamic dispatch, validating the target (native or bytecode) and reorganizing stack variables before initiating the call (`call.zig`).
  * Properties: Structs use statically compiled `OP_GET_INDEX` offsets. Dynamic module or error properties use `OP_GET_PROPERTY`, doing string lookups at runtime.

## 5. Error Handling & Diagnostics

The VM uses a dedicated subsystem (`src/errors/`) to report issues robustly.
* **`diag.zig` & `report.zig`**: Provide functions for formatting contextual source errors, showing the file, line, column, and a precise snippet of the code where the error occurred.
* **`runtime.zig` & `stack_trace.zig`**: Handle runtime failures by printing a diagnostic source context followed by a full stack trace. When `runtimeFail` is triggered (e.g., from a watchdog timeout or an explicit `RuntimeError`), it unwinds `VMState.frames`, mapping each frame to its source location using the metadata stored in `CallFrame`.
* **Integration**: The VM and Compiler both funnel errors through this API to ensure users receive consistent, colorized, and detailed diagnostic output rather than raw panics.

## 6. IO & Logging Subsystem

The IO subsystem (`src/io/`) replaces direct standard library print calls with a structured, robust I/O pipeline:
* **Logging (`log.zig`)**: Provides leveled logging (`.trace`, `.debug`, `.info`, `.warn`, `.err`). The minimum log level can be configured via environment variables (e.g., `LLTS_LOG_LEVEL`).
* **Output (`out.zig`)**: Manages low-level writes to `STDOUT` and `STDERR`, specifically handling short writes and `EINTR` signals gracefully through POSIX bindings. It replaces `std.debug.print` in the VM's execution path.
* **Colors (`color.zig`)**: Supplies ANSI color formatting for both the logger and the diagnostic error reporter.

## 7. Module Resolution

Module instances and global variables are resolved via hash maps in the VM (`VMState.modules` and `VMState.globals`).
* The compiler and VM work together to manage cross-module dependencies, utilizing the new diagnostic system if a module fails to load or resolve.
* Global constants and module exports are resolved at compile/load time and inserted into these maps, ensuring that dynamic property lookups (`OP_GET_PROPERTY`) and module accesses are handled efficiently and deterministically at runtime.
