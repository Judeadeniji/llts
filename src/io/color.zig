const std = @import("std");

/// ANSI styling for diagnostics and logs. Off by default when stderr is not a
/// TTY or when `NO_COLOR` is set. Force on with `FORCE_COLOR=1` / `LLTS_COLOR=1`.

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";

pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const white = "\x1b[37m";

pub const bright_red = "\x1b[91m";
pub const bright_yellow = "\x1b[93m";
pub const bright_cyan = "\x1b[96m";

var enabled_flag: bool = false;
var initialized: bool = false;

fn stderrIsTty() bool {
    return std.posix.isatty(std.posix.STDERR_FILENO);
}

fn envTruthy(name: []const u8) bool {
    const v = std.posix.getenv(name) orelse return false;
    if (v.len == 0) return false;
    if (std.mem.eql(u8, v, "0")) return false;
    if (std.ascii.eqlIgnoreCase(v, "false")) return false;
    if (std.ascii.eqlIgnoreCase(v, "off")) return false;
    return true;
}

pub fn initFromEnv() void {
    initialized = true;
    // Force wins (Heroku/CI convention); then NO_COLOR; else TTY detect.
    if (envTruthy("FORCE_COLOR") or envTruthy("LLTS_COLOR")) {
        enabled_flag = true;
        return;
    }
    if (std.posix.getenv("NO_COLOR")) |v| {
        if (v.len > 0) {
            enabled_flag = false;
            return;
        }
    }
    enabled_flag = stderrIsTty();
}

pub fn setEnabled(on: bool) void {
    initialized = true;
    enabled_flag = on;
}

pub fn enabled() bool {
    if (!initialized) initFromEnv();
    return enabled_flag;
}

/// Return `code` when color is on, else empty string.
pub fn paint(code: []const u8) []const u8 {
    return if (enabled()) code else "";
}

pub fn r() []const u8 {
    return paint(reset);
}
