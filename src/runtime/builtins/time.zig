//! LLTS native time functions — mirrors `src/vm/builtins/time.zig`.
//!
//! Two natives: `__now()` returns the current unix time in nanoseconds
//! (i64), and `__sleep(d)` sleeps for `d` nanoseconds. All arithmetic
//! conversions live in `std/time.lls`.

const std = @import("std");

export fn __now() i64 {
    return @intCast(std.time.nanoTimestamp());
}

export fn __sleep(d: i64) i64 {
    if (d <= 0) return 0;
    const ns: u64 = @intCast(d);
    std.Thread.sleep(ns);
    return 0;
}
