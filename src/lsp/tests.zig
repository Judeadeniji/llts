//! Unit tests for the LSP server internals (not the binary).
//! Referenced as a test root from build.zig; add new modules here.

const uri = @import("uri.zig");
const resolve = @import("resolve.zig");
const infer_test = @import("infer_test.zig");
const analysis_debug_test = @import("analysis_debug_test.zig");
const handlers = @import("handlers.zig");

test {
    _ = uri;
    _ = resolve;
    _ = infer_test;
    _ = analysis_debug_test;
    _ = handlers;
}
