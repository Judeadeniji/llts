pub const out = @import("out.zig");
pub const log = @import("log.zig");
pub const color = @import("color.zig");

pub const writeStdout = out.writeStdout;
pub const writeStderr = out.writeStderr;
pub const printStdout = out.printStdout;
pub const printStderr = out.printStderr;
pub const Level = log.Level;
