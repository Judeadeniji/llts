//! Native `len`-related functions (mirrors `src/vm/builtins/len.zig`).
//!
//! `len` itself is special-cased in the LLVM backend (`src/compiler/llvm/expr.zig`):
//! fixed arrays lower to a compile-time constant, strings lower to `__strlen`,
//! and open slices / native arrays lower to `__arrayLen`.

const std = @import("std");
const util = @import("util.zig");

export fn __strlen(s: [*:0]const u8) i64 {
    return @intCast(util.cstr(s).len);
}

export fn __arrayLen(arr: [*]align(8) const u8) i64 {
    return @intCast(util.arrayCount(arr));
}
