const std = @import("std");
const ops = @import("ops.zig");

pub const PRECEDENCE = struct {
    pub fn of(op: []const u8) i32 {
        // C / Zig-ish: logical → bitwise → compare → shift → arith → power
        if (ops.isAssignOp(op)) return 1;
        if (std.mem.eql(u8, op, "||")) return 2;
        if (std.mem.eql(u8, op, "&&")) return 3;
        if (std.mem.eql(u8, op, "|")) return 4;
        if (std.mem.eql(u8, op, "~")) return 5; // binary XOR (`^` stays power)
        if (std.mem.eql(u8, op, "&")) return 6;
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) return 7;
        if (std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=") or
            std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=")) return 8;
        if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) return 9;
        if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "|>")) return 10;
        if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/") or
            std.mem.eql(u8, op, "%") or std.mem.eql(u8, op, "**")) return 11;
        if (std.mem.eql(u8, op, "^")) return 12;
        if (std.mem.eql(u8, op, "..")) return 13;
        return -1;
    }
};
