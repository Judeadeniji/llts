const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");

const CompilerState = state_mod.CompilerState;

pub const ConstEnv = struct {
    const_names: std.StringHashMap(void),

    pub fn deinit(self: *ConstEnv) void {
        self.const_names.deinit();
    }
};

pub fn createConstEnv(state: *CompilerState) !ConstEnv {
    var env: ConstEnv = .{
        .const_names = std.StringHashMap(void).init(state.allocator),
    };
    var it = state.global_consts.keyIterator();
    while (it.next()) |name| {
        try env.const_names.put(name.*, {});
    }
    var git = state.global_types.iterator();
    while (git.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, "$") and std.mem.startsWith(u8, e.value_ptr.*, "module:")) {
            try env.const_names.put(e.key_ptr.*[1..], {});
        }
    }
    return env;
}

pub fn isConstantExpr(state: *CompilerState, env: *const ConstEnv, node: ?*ast.Node) bool {
    const n = node orelse return false;
    return switch (n.*) {
        .literal => true,
        .primary => |p| blk: {
            if (p.kind != .identifier and p.kind != .register) break :blk false;
            if (std.mem.eql(u8, p.name, "null") or std.mem.eql(u8, p.name, "true") or std.mem.eql(u8, p.name, "false"))
                break :blk true;
            break :blk env.const_names.contains(p.name);
        },
        .unary => |u| isConstantExpr(state, env, u.arg),
        .binary => |b| blk: {
            if (std.mem.eql(u8, b.operator, "|>") or std.mem.eql(u8, b.operator, "..")) break :blk false;
            break :blk isConstantExpr(state, env, b.left) and isConstantExpr(state, env, b.right);
        },
        .array_literal => |a| blk: {
            for (a.elements) |e| {
                if (!isConstantExpr(state, env, e)) break :blk false;
            }
            break :blk true;
        },
        .struct_init => |s| blk: {
            for (s.fields) |f| {
                if (!isConstantExpr(state, env, f.value)) break :blk false;
            }
            break :blk true;
        },
        .import => true,
        .call => |c| blk: {
            if (c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@typeOf"))
                break :blk true;
            break :blk false;
        },
        .error_expr => |e| isConstantExpr(state, env, e.message),
        else => false,
    };
}
