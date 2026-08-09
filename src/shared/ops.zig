const std = @import("std");

pub const BinOps = struct {
    pub const values = [_][]const u8{
        "+",  "-",  "*",  "/",  "%",  "^",  "==", "!=", ">", ">=", "<", "<=",
        "&&", "||", "**", "|>", "..",
    };
};

pub const UnaryOps = struct {
    pub const values = [_][]const u8{ "!", "-" };
};

pub const AssignOps = struct {
    pub const values = [_][]const u8{
        "=", "+=", "-=", "*=", "/=", "%=", "^=", "&&=", "||=",
    };
};

pub fn isBinOp(s: []const u8) bool {
    for (BinOps.values) |v| {
        if (std.mem.eql(u8, v, s)) return true;
    }
    return false;
}

pub fn isUnaryOp(s: []const u8) bool {
    for (UnaryOps.values) |v| {
        if (std.mem.eql(u8, v, s)) return true;
    }
    return false;
}

pub fn isAssignOp(s: []const u8) bool {
    for (AssignOps.values) |v| {
        if (std.mem.eql(u8, v, s)) return true;
    }
    return false;
}
