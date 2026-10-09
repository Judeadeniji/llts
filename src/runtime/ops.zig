// Runtime operation primitives — the concrete functions that emitted native Zig
// code calls instead of dispatching bytecode ops.
//
// Examples (Phase 1 targets):
//   opAddI64(a, b)             — checked integer addition
//   opLoadField(ctx, obj, off) — packed heap field load
//   opMakeError(ctx, msg)      — construct an LLTS error value
//   opIsError(val)             — test whether a value is an error
//
// Phase 1 stub — implementation pending.
