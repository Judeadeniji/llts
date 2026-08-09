const std = @import("std");
const ops = @import("ops.zig");

pub const PRECEDENCE = struct {
    pub fn of(op: []const u8) i32 {
        if (ops.isAssignOp(op)) return 1;
        if (std.mem.eql(u8, op, "||")) return 2;
        if (std.mem.eql(u8, op, "&&")) return 3;
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) return 4;
        if (std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=") or
            std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=")) return 5;
        if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "|>")) return 6;
        if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/") or
            std.mem.eql(u8, op, "%") or std.mem.eql(u8, op, "**")) return 7;
        if (std.mem.eql(u8, op, "^")) return 8;
        if (std.mem.eql(u8, op, "..")) return 9;
        return -1;
    }
};
