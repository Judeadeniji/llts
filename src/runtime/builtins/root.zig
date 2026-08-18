//! Compilation entry for the native runtime builtins. The comptime block
//! forces analysis of every builtin module so their `export fn`s are all
//! emitted into the object.

const util = @import("util.zig");
const len = @import("len.zig");
const string = @import("string.zig");
const math = @import("math.zig");
const syscall = @import("syscall.zig");
const buffer = @import("buffer.zig");
const os = @import("os.zig");
const time = @import("time.zig");
const list = @import("list.zig");
const map = @import("map.zig");
const json = @import("json.zig");
const http = @import("http.zig");
const debug = @import("debug.zig");

comptime {
    _ = util;
    _ = len;
    _ = string;
    _ = math;
    _ = syscall;
    _ = buffer;
    _ = os;
    _ = time;
    _ = list;
    _ = map;
    _ = json;
    _ = http;
    _ = debug;
}
