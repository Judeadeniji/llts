const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const compile_errors = @import("../errors/compile.zig");
const from_ast = @import("typecheck/from_ast.zig");
const path = @import("expr/path.zig");
const emit = @import("emit.zig");
const layout = @import("layout.zig");

const CompilerState = state_mod.CompilerState;

pub const DEFAULT_COMPTIME_MAX_LOOP_ITERATIONS: usize = 100_000;

pub const ConstArray = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayList(ConstValue) = .empty,

    pub fn init(allocator: std.mem.Allocator) ConstArray {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConstArray) void {
        self.elements.deinit(self.allocator);
    }

    pub fn append(self: *ConstArray, v: ConstValue) !void {
        try self.elements.append(self.allocator, v);
    }

    pub fn ensureCapacity(self: *ConstArray, n: usize) !void {
        try self.elements.ensureTotalCapacity(self.allocator, n);
    }
};

pub const ConstStruct = struct {
    type_name: []const u8,
    fields: std.StringHashMap(ConstValue),

    pub fn init(allocator: std.mem.Allocator, type_name: []const u8) ConstStruct {
        return .{
            .type_name = type_name,
            .fields = std.StringHashMap(ConstValue).init(allocator),
        };
    }

    pub fn deinit(self: *ConstStruct) void {
        self.fields.deinit();
    }
};

/// Structural equality for switch-pattern matching at compile time. Aggregates
/// are never valid switch patterns, so they compare by identity (false).
pub fn constValueEql(a: ConstValue, b: ConstValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .i64 => |x| x == b.i64,
        .f64 => |x| x == b.f64,
        .string => |x| std.mem.eql(u8, x, b.string),
        .enum_variant => |e| e.tag == b.enum_variant.tag and std.mem.eql(u8, e.enum_name, b.enum_variant.enum_name),
        .array, .tuple, .struct_val => false,
    };
}

pub const ConstValue = union(enum) {
    null,
    bool: bool,
    i64: i64,
    f64: f64,
    string: []const u8,
    array: *ConstArray,
    tuple: []ConstValue,
    struct_val: *ConstStruct,
    enum_variant: struct {
        enum_name: []const u8,
        variant_name: []const u8,
        tag: i64,
    },

    pub fn isTruthy(self: ConstValue) bool {
        return switch (self) {
            .null => false,
            .bool => |b| b,
            .i64 => |n| n != 0,
            .f64 => |f| f != 0.0,
            .string => |s| s.len > 0,
            .array => |a| a.elements.items.len > 0,
            .tuple => |t| t.len > 0,
            .struct_val => true,
            .enum_variant => true,
        };
    }

    pub fn clone(self: ConstValue, allocator: std.mem.Allocator) !ConstValue {
        switch (self) {
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .array => |a| {
                const new_arr = try allocator.create(ConstArray);
                new_arr.* = ConstArray.init(allocator);
                try new_arr.ensureCapacity(a.elements.items.len);
                for (a.elements.items) |item| {
                    try new_arr.append(try item.clone(allocator));
                }
                return .{ .array = new_arr };
            },
            .tuple => |t| {
                const new_t = try allocator.alloc(ConstValue, t.len);
                for (t, 0..) |item, i| {
                    new_t[i] = try item.clone(allocator);
                }
                return .{ .tuple = new_t };
            },
            .struct_val => |s| {
                const new_s = try allocator.create(ConstStruct);
                new_s.* = ConstStruct.init(allocator, try allocator.dupe(u8, s.type_name));
                var it = s.fields.iterator();
                while (it.next()) |entry| {
                    const k = try allocator.dupe(u8, entry.key_ptr.*);
                    const v = try entry.value_ptr.clone(allocator);
                    try new_s.fields.put(k, v);
                }
                return .{ .struct_val = new_s };
            },
            else => return self,
        }
    }
};

pub const ComptimeScope = struct {
    allocator: std.mem.Allocator,
    locals: std.StringHashMap(ConstValue),
    const_names: std.StringHashMap(void),
    parent: ?*ComptimeScope = null,
    is_loop: bool = false,
    broken_val: ?ConstValue = null,
    returned_val: ?ConstValue = null,
    has_broken: bool = false,
    has_returned: bool = false,
    has_continued: bool = false,

    pub fn init(allocator: std.mem.Allocator, parent: ?*ComptimeScope) ComptimeScope {
        return .{
            .allocator = allocator,
            .locals = std.StringHashMap(ConstValue).init(allocator),
            .const_names = std.StringHashMap(void).init(allocator),
            .parent = parent,
        };
    }

    pub fn initLoop(allocator: std.mem.Allocator, parent: ?*ComptimeScope) ComptimeScope {
        return .{
            .allocator = allocator,
            .locals = std.StringHashMap(ConstValue).init(allocator),
            .const_names = std.StringHashMap(void).init(allocator),
            .parent = parent,
            .is_loop = true,
        };
    }

    pub fn deinit(self: *ComptimeScope) void {
        self.locals.deinit();
        self.const_names.deinit();
    }

    pub fn get(self: *const ComptimeScope, name: []const u8) ?ConstValue {
        if (self.locals.get(name)) |v| return v;
        if (name.len > 0 and name[0] == '$') {
            if (self.locals.get(name[1..])) |v| return v;
        } else {
            var buf: [128]u8 = undefined;
            if (name.len + 1 <= buf.len) {
                buf[0] = '$';
                @memcpy(buf[1 .. name.len + 1], name);
                if (self.locals.get(buf[0 .. name.len + 1])) |v| return v;
            }
        }
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn contains(self: *const ComptimeScope, name: []const u8) bool {
        if (self.locals.contains(name)) return true;
        if (name.len > 0 and name[0] == '$') {
            if (self.locals.contains(name[1..])) return true;
        } else {
            var buf: [128]u8 = undefined;
            if (name.len + 1 <= buf.len) {
                buf[0] = '$';
                @memcpy(buf[1 .. name.len + 1], name);
                if (self.locals.contains(buf[0 .. name.len + 1])) return true;
            }
        }
        if (self.parent) |p| return p.contains(name);
        return false;
    }

    pub fn isConst(self: *const ComptimeScope, name: []const u8) bool {
        if (self.const_names.contains(name)) return true;
        if (name.len > 0 and name[0] == '$') {
            if (self.const_names.contains(name[1..])) return true;
        } else {
            var buf: [128]u8 = undefined;
            if (name.len + 1 <= buf.len) {
                buf[0] = '$';
                @memcpy(buf[1 .. name.len + 1], name);
                if (self.const_names.contains(buf[0 .. name.len + 1])) return true;
            }
        }
        if (self.parent) |p| return p.isConst(name);
        return false;
    }

    pub fn put(self: *ComptimeScope, name: []const u8, val: ConstValue) !void {
        try self.locals.put(name, val);
        if (name.len > 0 and name[0] == '$') {
            try self.locals.put(name[1..], val);
        }
    }

    pub fn putConst(self: *ComptimeScope, name: []const u8, val: ConstValue) !void {
        try self.put(name, val);
        try self.const_names.put(name, {});
        if (name.len > 0 and name[0] == '$') {
            try self.const_names.put(name[1..], {});
        }
    }

    pub fn update(self: *ComptimeScope, name: []const u8, val: ConstValue) bool {
        if (self.locals.contains(name)) {
            self.locals.put(name, val) catch return false;
            if (name.len > 0 and name[0] == '$') {
                self.locals.put(name[1..], val) catch {};
            }
            return true;
        }
        if (name.len > 0 and name[0] == '$') {
            if (self.locals.contains(name[1..])) {
                self.locals.put(name[1..], val) catch return false;
                self.locals.put(name, val) catch {};
                return true;
            }
        }
        if (self.parent) |p| return p.update(name, val);
        return false;
    }
};

fn isConstBinding(state: *CompilerState, scope: ?*const ComptimeScope, name: []const u8) bool {
    if (scope) |s| {
        if (s.isConst(name)) return true;
        if (s.contains(name)) return false;
    }
    if (state.global_consts.contains(name)) return true;
    if (state.const_values.contains(name)) return true;
    if (state.ready_global_consts.contains(name)) return true;
    if (name.len > 0 and name[0] == '$') {
        const bare = name[1..];
        if (state.global_consts.contains(bare)) return true;
        if (state.const_values.contains(bare)) return true;
        if (state.ready_global_consts.contains(bare)) return true;
    }
    return false;
}

fn parseIntWithUnderscores(raw: []const u8, radix: u8) !i64 {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return error.CompileError;
        buf[len] = c;
        len += 1;
    }
    return std.fmt.parseInt(i64, buf[0..len], radix);
}

fn parseFloatWithUnderscores(raw: []const u8) !f64 {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return error.CompileError;
        buf[len] = c;
        len += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..len]);
}

pub fn evalLiteral(lit: *const ast.Literal) !ConstValue {
    switch (lit.literal_type) {
        .@"null" => return .null,
        .boolean => return .{ .bool = std.mem.eql(u8, lit.value, "true") },
        .string => return .{ .string = lit.value },
        .number => {
            if (std.mem.indexOfScalar(u8, lit.value, '.')) |_| {
                const f = try parseFloatWithUnderscores(lit.value);
                return .{ .f64 = f };
            } else {
                const n = try parseIntWithUnderscores(lit.value, 10);
                return .{ .i64 = n };
            }
        },
        .hex => {
            const n = try parseIntWithUnderscores(lit.value[2..], 16);
            return .{ .i64 = n };
        },
        .octal => {
            const n = try parseIntWithUnderscores(lit.value[2..], 8);
            return .{ .i64 = n };
        },
        .binary => {
            const n = try parseIntWithUnderscores(lit.value[2..], 2);
            return .{ .i64 = n };
        },
    }
}

fn noteDiag(state: *CompilerState, node: *ast.Node) void {
    const loc = node.loc();
    if (loc.line > 0) state.diag_line = loc.line;
    if (loc.column > 0) state.diag_column = loc.column;
    if (loc.path.len > 0) state.diag_path = loc.path;
}

pub fn evalBinaryOp(state: *CompilerState, op: []const u8, left_val: ConstValue, right_val: ConstValue) anyerror!?ConstValue {
    if (std.mem.eql(u8, op, "+")) {
        if (left_val == .i64 and right_val == .i64) {
            const r = @addWithOverflow(left_val.i64, right_val.i64);
            if (r[1] != 0) return compile_errors.compileFailFmt(state, "integer overflow in constant expression", .{});
            return .{ .i64 = r[0] };
        }
        if (left_val == .f64 and right_val == .f64) return .{ .f64 = left_val.f64 + right_val.f64 };
        if (left_val == .string and right_val == .string) {
            const joined = try std.mem.concat(state.allocator, u8, &[_][]const u8{ left_val.string, right_val.string });
            return .{ .string = joined };
        }
        return null;
    }
    if (std.mem.eql(u8, op, "+%")) {
        if (left_val == .i64 and right_val == .i64) return .{ .i64 = left_val.i64 +% right_val.i64 };
        return null;
    }
    if (std.mem.eql(u8, op, "-")) {
        if (left_val == .i64 and right_val == .i64) {
            const r = @subWithOverflow(left_val.i64, right_val.i64);
            if (r[1] != 0) return compile_errors.compileFailFmt(state, "integer overflow in constant expression", .{});
            return .{ .i64 = r[0] };
        }
        if (left_val == .f64 and right_val == .f64) return .{ .f64 = left_val.f64 - right_val.f64 };
        return null;
    }
    if (std.mem.eql(u8, op, "-%")) {
        if (left_val == .i64 and right_val == .i64) return .{ .i64 = left_val.i64 -% right_val.i64 };
        return null;
    }
    if (std.mem.eql(u8, op, "*")) {
        if (left_val == .i64 and right_val == .i64) {
            const r = @mulWithOverflow(left_val.i64, right_val.i64);
            if (r[1] != 0) return compile_errors.compileFailFmt(state, "integer overflow in constant expression", .{});
            return .{ .i64 = r[0] };
        }
        if (left_val == .f64 and right_val == .f64) return .{ .f64 = left_val.f64 * right_val.f64 };
        return null;
    }
    if (std.mem.eql(u8, op, "*%")) {
        if (left_val == .i64 and right_val == .i64) return .{ .i64 = left_val.i64 *% right_val.i64 };
        return null;
    }
    if (std.mem.eql(u8, op, "/")) {
        if (left_val == .i64 and right_val == .i64) {
            if (right_val.i64 == 0) {
                return compile_errors.compileFailFmt(state, "division by zero in constant expression", .{});
            }
            return .{ .i64 = @divTrunc(left_val.i64, right_val.i64) };
        }
        if (left_val == .f64 and right_val == .f64) {
            if (right_val.f64 == 0.0) {
                return compile_errors.compileFailFmt(state, "division by zero in constant expression", .{});
            }
            return .{ .f64 = left_val.f64 / right_val.f64 };
        }
        return null;
    }
    if (std.mem.eql(u8, op, "%")) {
        if (left_val == .i64 and right_val == .i64) {
            if (right_val.i64 == 0) {
                return compile_errors.compileFailFmt(state, "division by zero in constant expression", .{});
            }
            return .{ .i64 = @rem(left_val.i64, right_val.i64) };
        }
        return null;
    }
    if (std.mem.eql(u8, op, "&")) {
        if (left_val == .i64 and right_val == .i64) return .{ .i64 = left_val.i64 & right_val.i64 };
        return null;
    }
    if (std.mem.eql(u8, op, "|")) {
        if (left_val == .i64 and right_val == .i64) return .{ .i64 = left_val.i64 | right_val.i64 };
        return null;
    }
    if (std.mem.eql(u8, op, "^") or std.mem.eql(u8, op, "~")) {
        if (left_val == .i64 and right_val == .i64) return .{ .i64 = left_val.i64 ^ right_val.i64 };
        return null;
    }
    if (std.mem.eql(u8, op, "<<")) {
        if (left_val == .i64 and right_val == .i64) {
            if (right_val.i64 < 0 or right_val.i64 >= 64) return null;
            return .{ .i64 = left_val.i64 << @intCast(right_val.i64) };
        }
        return null;
    }
    if (std.mem.eql(u8, op, ">>")) {
        if (left_val == .i64 and right_val == .i64) {
            if (right_val.i64 < 0 or right_val.i64 >= 64) return null;
            return .{ .i64 = left_val.i64 >> @intCast(right_val.i64) };
        }
        return null;
    }
    if (std.mem.eql(u8, op, "==")) {
        if (left_val == .i64 and right_val == .i64) return .{ .bool = left_val.i64 == right_val.i64 };
        if (left_val == .bool and right_val == .bool) return .{ .bool = left_val.bool == right_val.bool };
        if (left_val == .string and right_val == .string) return .{ .bool = std.mem.eql(u8, left_val.string, right_val.string) };
        if (left_val == .null and right_val == .null) return .{ .bool = true };
        return .{ .bool = false };
    }
    if (std.mem.eql(u8, op, "!=")) {
        if (left_val == .i64 and right_val == .i64) return .{ .bool = left_val.i64 != right_val.i64 };
        if (left_val == .bool and right_val == .bool) return .{ .bool = left_val.bool != right_val.bool };
        if (left_val == .string and right_val == .string) return .{ .bool = !std.mem.eql(u8, left_val.string, right_val.string) };
        if (left_val == .null and right_val == .null) return .{ .bool = false };
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, op, "<")) {
        if (left_val == .i64 and right_val == .i64) return .{ .bool = left_val.i64 < right_val.i64 };
        if (left_val == .f64 and right_val == .f64) return .{ .bool = left_val.f64 < right_val.f64 };
        return null;
    }
    if (std.mem.eql(u8, op, "<=")) {
        if (left_val == .i64 and right_val == .i64) return .{ .bool = left_val.i64 <= right_val.i64 };
        if (left_val == .f64 and right_val == .f64) return .{ .bool = left_val.f64 <= right_val.f64 };
        return null;
    }
    if (std.mem.eql(u8, op, ">")) {
        if (left_val == .i64 and right_val == .i64) return .{ .bool = left_val.i64 > right_val.i64 };
        if (left_val == .f64 and right_val == .f64) return .{ .bool = left_val.f64 > right_val.f64 };
        return null;
    }
    if (std.mem.eql(u8, op, ">=")) {
        if (left_val == .i64 and right_val == .i64) return .{ .bool = left_val.i64 >= right_val.i64 };
        if (left_val == .f64 and right_val == .f64) return .{ .bool = left_val.f64 >= right_val.f64 };
        return null;
    }
    if (std.mem.eql(u8, op, "&&")) {
        return .{ .bool = left_val.isTruthy() and right_val.isTruthy() };
    }
    if (std.mem.eql(u8, op, "||")) {
        return .{ .bool = left_val.isTruthy() or right_val.isTruthy() };
    }
    return null;
}

pub fn evalExpr(state: *CompilerState, scope: ?*ComptimeScope, node: ?*ast.Node) anyerror!?ConstValue {
    const n = node orelse return null;
    const prev_line = state.diag_line;
    const prev_column = state.diag_column;
    const prev_path = state.diag_path;
    noteDiag(state, n);
    const value = try evalExprInner(state, scope, n);
    // Restore the prior location on success so a later failure at a parent
    // node is attributed there rather than to the last child we visited.
    state.diag_line = prev_line;
    state.diag_column = prev_column;
    state.diag_path = prev_path;
    return value;
}

fn evalExprInner(state: *CompilerState, scope: ?*ComptimeScope, n: *ast.Node) anyerror!?ConstValue {
    switch (n.*) {
        .literal => |lit| {
            return evalLiteral(&lit) catch null;
        },
        .primary => |p| {
            if (std.mem.eql(u8, p.name, "null")) return .null;
            if (std.mem.eql(u8, p.name, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, p.name, "false")) return .{ .bool = false };

            if (scope) |s| {
                if (s.get(p.name)) |v| return v;
            }

            if (state.const_values.get(p.name)) |v| return v;
            if (p.name.len > 0 and p.name[0] == '$') {
                if (state.const_values.get(p.name[1..])) |v| return v;
            } else {
                var buf: [128]u8 = undefined;
                if (p.name.len + 1 <= buf.len) {
                    buf[0] = '$';
                    @memcpy(buf[1 .. p.name.len + 1], p.name);
                    if (state.const_values.get(buf[0 .. p.name.len + 1])) |v| return v;
                }
            }

            return null;
        },
        .unary => |u| {
            const arg_val = (try evalExpr(state, scope, u.arg)) orelse return null;
            if (std.mem.eql(u8, u.operator, "-")) {
                return switch (arg_val) {
                    .i64 => |v| blk: {
                        if (v == std.math.minInt(i64)) return compile_errors.compileFailFmt(state, "integer overflow in constant expression", .{});
                        break :blk .{ .i64 = -v };
                    },
                    .f64 => |v| .{ .f64 = -v },
                    else => null,
                };
            }
            if (std.mem.eql(u8, u.operator, "+")) {
                return switch (arg_val) {
                    .i64, .f64 => arg_val,
                    else => null,
                };
            }
            if (std.mem.eql(u8, u.operator, "!")) {
                return .{ .bool = !arg_val.isTruthy() };
            }
            if (std.mem.eql(u8, u.operator, "~")) {
                return switch (arg_val) {
                    .i64 => |v| .{ .i64 = ~v },
                    else => null,
                };
            }
            return null;
        },
        .binary => |b| {
            const left_val = (try evalExpr(state, scope, b.left)) orelse return null;
            const right_val = (try evalExpr(state, scope, b.right)) orelse return null;
            return try evalBinaryOp(state, b.operator, left_val, right_val);
        },
        .array_literal => |arr| {
            const carr = try state.allocator.create(ConstArray);
            carr.* = ConstArray.init(state.allocator);
            try carr.ensureCapacity(arr.elements.len);
            for (arr.elements) |elem| {
                const evaled = (try evalExpr(state, scope, elem)) orelse return null;
                try carr.append(evaled);
            }
            return .{ .array = carr };
        },
        .struct_init => |s| {
            var type_name: []const u8 = "Struct";
            if (s.type_expr.* == .primary) {
                type_name = s.type_expr.primary.name;
            }
            const cstruct = try state.allocator.create(ConstStruct);
            cstruct.* = ConstStruct.init(state.allocator, type_name);
            for (s.fields) |f| {
                const fval = (try evalExpr(state, scope, f.value)) orelse return null;
                try cstruct.fields.put(f.name, fval);
            }
            return .{ .struct_val = cstruct };
        },
        .index => |idx| {
            const obj_val = (try evalExpr(state, scope, idx.object)) orelse return null;
            const start_expr = idx.index orelse return null;
            const index_val = (try evalExpr(state, scope, start_expr)) orelse return null;
            if (index_val != .i64) return null;
            const i = index_val.i64;

            switch (obj_val) {
                .array => |a| {
                    if (i < 0 or i >= a.elements.items.len) {
                        return compile_errors.compileFailFmt(state, "index {d} out of bounds for array of length {d}", .{ i, a.elements.items.len });
                    }
                    return a.elements.items[@intCast(i)];
                },
                .tuple => |t| {
                    if (i < 0 or i >= t.len) {
                        return compile_errors.compileFailFmt(state, "index {d} out of bounds for tuple of length {d}", .{ i, t.len });
                    }
                    return t[@intCast(i)];
                },
                .string => |s| {
                    if (i < 0 or i >= s.len) {
                        return compile_errors.compileFailFmt(state, "index {d} out of bounds for string of length {d}", .{ i, s.len });
                    }
                    return .{ .i64 = @intCast(s[@intCast(i)]) };
                },
                else => return null,
            }
        },
        .member => |m| {
            if (m.property.* != .primary) return null;
            const prop_name = m.property.primary.name;

            // Enum variant check: Color.Red
            if (from_ast.resolveEnumName(state, m.object)) |ename| {
                if (state.enums.get(ename)) |ed| {
                    if (ed.variants.get(prop_name)) |tag| {
                        return .{ .enum_variant = .{
                            .enum_name = ename,
                            .variant_name = prop_name,
                            .tag = tag,
                        } };
                    }
                }
            }

            const obj_val = (try evalExpr(state, scope, m.object)) orelse return null;
            switch (obj_val) {
                .struct_val => |s| {
                    if (s.fields.get(prop_name)) |fval| {
                        return fval;
                    }
                    return compile_errors.compileFailFmt(state, "field '{s}' does not exist on '{s}'", .{ prop_name, s.type_name });
                },
                .tuple => |t| {
                    const idx = std.fmt.parseInt(usize, prop_name, 10) catch return null;
                    if (idx >= t.len) {
                        return compile_errors.compileFailFmt(state, "Tuple index {d} out of range (len {d})", .{ idx, t.len });
                    }
                    return t[idx];
                },
                .array => |a| {
                    const idx = std.fmt.parseInt(usize, prop_name, 10) catch return null;
                    if (idx >= a.elements.items.len) {
                        return compile_errors.compileFailFmt(state, "Index {d} out of range (len {d})", .{ idx, a.elements.items.len });
                    }
                    return a.elements.items[idx];
                },
                else => return null,
            }
        },
        .call => |c| {
            if (c.callee.* == .primary) {
                const callee_name = c.callee.primary.name;
                if (std.mem.eql(u8, callee_name, "len")) {
                    if (c.args.len != 1) return null;
                    const arg_val = (try evalExpr(state, scope, c.args[0])) orelse return null;
                    switch (arg_val) {
                        .array => |a| return .{ .i64 = @intCast(a.elements.items.len) },
                        .tuple => |t| return .{ .i64 = @intCast(t.len) },
                        .string => |s| return .{ .i64 = @intCast(s.len) },
                        else => return null,
                    }
                }
            }
            return try evalComptimeCall(state, scope, &c);
        },
        .comptime_expr => |ce| {
            if (ce.expr.* == .block) {
                return try evalComptimeBlock(state, scope, &ce.expr.block);
            }
            return try evalExpr(state, scope, ce.expr);
        },
        .block => |b| {
            return try evalComptimeBlock(state, scope, &b);
        },
        else => return null,
    }
}

/// Evaluates a `@comptime` block. Returns `null` when the block cannot be
/// evaluated (e.g. it references a run-time binding); callers distinguish that
/// from a genuine `null` value, which is `.null` wrapped in the optional.
pub fn evalComptimeBlock(state: *CompilerState, parent_scope: ?*ComptimeScope, block: *const ast.Block) anyerror!?ConstValue {
    var bscope = ComptimeScope.init(state.allocator, parent_scope);
    defer bscope.deinit();
    // `return` is non-local: propagate it out of nested blocks so a `return`
    // inside an `@if` / `@for` / `@switch` body in a comptime block reaches the
    // enclosing evaluation. Blocks that merely yield a value via `break` stay
    // local, so only `has_returned` is forwarded here.
    defer if (parent_scope) |parent| {
        if (bscope.has_returned) {
            parent.has_returned = true;
            parent.returned_val = bscope.returned_val;
        }
        if (!bscope.is_loop) {
            if (bscope.has_broken) {
                parent.has_broken = true;
                parent.broken_val = bscope.broken_val;
            }
            if (bscope.has_continued) {
                parent.has_continued = true;
            }
        }
    };

    var last_val: ConstValue = .null;
    for (block.statements) |stmt_node| {
        if (bscope.has_broken or bscope.has_returned or bscope.has_continued) break;
        noteDiag(state, stmt_node);
        switch (stmt_node.*) {
            .declaration => |d| {
                const val = (try evalExpr(state, &bscope, d.value)) orelse return null;
                if (d.is_const) {
                    try bscope.putConst(d.name, val);
                } else {
                    try bscope.put(d.name, val);
                }
                last_val = val;
            },
            .assignment => |a| {
                const right_val = (try evalExpr(state, &bscope, a.right)) orelse return null;
                const is_compound = a.operator.len > 1 and a.operator[a.operator.len - 1] == '=';
                const compound_op = if (is_compound) a.operator[0 .. a.operator.len - 1] else null;

                if (a.left.* == .primary) {
                    const name = a.left.primary.name;
                    if (isConstBinding(state, &bscope, name)) {
                        return compile_errors.compileFailFmt(state, "Cannot mutate constant '{s}'", .{name});
                    }
                    var final_val = right_val;
                    if (compound_op) |cop| {
                        const cur_val = bscope.get(name) orelse (state.const_values.get(name) orelse return null);
                        final_val = (try evalBinaryOp(state, cop, cur_val, right_val)) orelse return null;
                    }
                    if (!bscope.update(name, final_val)) {
                        try bscope.put(name, final_val);
                    }
                    last_val = final_val;
                } else if (a.left.* == .index) {
                    if (a.left.index.object.* == .primary) {
                        const obj_name = a.left.index.object.primary.name;
                        if (isConstBinding(state, &bscope, obj_name)) {
                            return compile_errors.compileFailFmt(state, "Cannot mutate elements of constant '{s}'", .{obj_name});
                        }
                    }
                    const obj_val = (try evalExpr(state, &bscope, a.left.index.object)) orelse return compile_errors.compileFailFmt(state, "Cannot index assignment target in comptime", .{});
                    const start_expr = a.left.index.index orelse return compile_errors.compileFailFmt(state, "Expected index expression in comptime assignment", .{});
                    const idx_val = (try evalExpr(state, &bscope, start_expr)) orelse return compile_errors.compileFailFmt(state, "Index expression must evaluate to constant", .{});
                    if (idx_val != .i64) return compile_errors.compileFailFmt(state, "Index must be integer", .{});
                    const idx = idx_val.i64;
                    if (obj_val == .array) {
                        const a_obj = obj_val.array;
                        if (idx < 0 or idx >= a_obj.elements.items.len) {
                            return compile_errors.compileFailFmt(state, "index {d} out of bounds for array of length {d}", .{ idx, a_obj.elements.items.len });
                        }
                        var final_val = right_val;
                        if (compound_op) |cop| {
                            const cur_val = a_obj.elements.items[@intCast(idx)];
                            final_val = (try evalBinaryOp(state, cop, cur_val, right_val)) orelse return null;
                        }
                        a_obj.elements.items[@intCast(idx)] = final_val;
                        last_val = final_val;
                    } else {
                        return compile_errors.compileFailFmt(state, "Target is not a mutable array in comptime block", .{});
                    }
                } else if (a.left.* == .member) {
                    if (a.left.member.object.* == .primary) {
                        const obj_name = a.left.member.object.primary.name;
                        if (isConstBinding(state, &bscope, obj_name)) {
                            return compile_errors.compileFailFmt(state, "Cannot mutate field of constant '{s}'", .{obj_name});
                        }
                    }
                    const obj_val = (try evalExpr(state, &bscope, a.left.member.object)) orelse return compile_errors.compileFailFmt(state, "Cannot access member target in comptime", .{});
                    if (a.left.member.property.* != .primary) {
                        return compile_errors.compileFailFmt(state, "Expected identifier property in member assignment", .{});
                    }
                    const prop_name = a.left.member.property.primary.name;

                    if (obj_val == .struct_val) {
                        const s = obj_val.struct_val;
                        if (state.structs.get(s.type_name)) |sd| {
                            if (!sd.offsets.contains(prop_name)) {
                                return compile_errors.compileFailFmt(state, "field '{s}' does not exist on '{s}'", .{ prop_name, s.type_name });
                            }
                        }
                        var final_val = right_val;
                        if (compound_op) |cop| {
                            const cur_val = s.fields.get(prop_name) orelse return compile_errors.compileFailFmt(state, "field '{s}' not initialized on '{s}'", .{ prop_name, s.type_name });
                            final_val = (try evalBinaryOp(state, cop, cur_val, right_val)) orelse return null;
                        }
                        try s.fields.put(prop_name, final_val);
                        last_val = final_val;
                    } else if (obj_val == .tuple) {
                        const ci = std.fmt.parseInt(usize, prop_name, 10) catch
                            return compile_errors.compileFailFmt(state, "Tuple fields are numeric (.0, .1, …), got '.{s}'", .{prop_name});
                        if (ci >= obj_val.tuple.len) {
                            return compile_errors.compileFailFmt(state, "Tuple index {d} out of range (len {d})", .{ ci, obj_val.tuple.len });
                        }
                        var final_val = right_val;
                        if (compound_op) |cop| {
                            const cur_val = obj_val.tuple[ci];
                            final_val = (try evalBinaryOp(state, cop, cur_val, right_val)) orelse return null;
                        }
                        obj_val.tuple[ci] = final_val;
                        last_val = final_val;
                    } else if (obj_val == .array) {
                        const ci = std.fmt.parseInt(usize, prop_name, 10) catch
                            return compile_errors.compileFailFmt(state, "Tuple fields are numeric (.0, .1, …), got '.{s}'", .{prop_name});
                        if (ci >= obj_val.array.elements.items.len) {
                            return compile_errors.compileFailFmt(state, "Tuple index {d} out of range (len {d})", .{ ci, obj_val.array.elements.items.len });
                        }
                        var final_val = right_val;
                        if (compound_op) |cop| {
                            const cur_val = obj_val.array.elements.items[ci];
                            final_val = (try evalBinaryOp(state, cop, cur_val, right_val)) orelse return null;
                        }
                        obj_val.array.elements.items[ci] = final_val;
                        last_val = final_val;
                    } else {
                        return compile_errors.compileFailFmt(state, "Target is not a mutable struct, tuple, or array in comptime member assignment", .{});
                    }
                }
            },
            .for_expr => |f| {
                if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..")) {
                    const start_val = (try evalExpr(state, &bscope, f.expr.binary.left)) orelse return compile_errors.compileFailFmt(state, "for loop start bound must be constant in comptime", .{});
                    const end_val = (try evalExpr(state, &bscope, f.expr.binary.right)) orelse return compile_errors.compileFailFmt(state, "for loop end bound must be constant in comptime", .{});
                    if (start_val != .i64 or end_val != .i64) return compile_errors.compileFailFmt(state, "for loop bounds must be integers in comptime", .{});

                    const capture_name = if (f.captures.len > 0) f.captures[0].name else null;
                    var cur = start_val.i64;
                    const end = end_val.i64;
                    var iters: usize = 0;

                    while (cur < end) : (cur += 1) {
                        iters += 1;
                        if (iters > state.comptime_max_loop_iterations) {
                            return compile_errors.compileFailFmt(state, "comptime loop exceeded maximum iteration limit of {d}", .{state.comptime_max_loop_iterations});
                        }
                        var loop_scope = ComptimeScope.initLoop(state.allocator, &bscope);
                        defer loop_scope.deinit();

                        if (capture_name) |cname| {
                            try loop_scope.put(cname, .{ .i64 = cur });
                        }

                        if (f.body.* == .block) {
                            const res = try evalComptimeBlock(state, &loop_scope, &f.body.block);
                            if (loop_scope.has_broken) {
                                if (loop_scope.broken_val) |bv| last_val = bv;
                                break;
                            }
                            if (loop_scope.has_returned) {
                                bscope.has_returned = true;
                                bscope.returned_val = loop_scope.returned_val;
                                return loop_scope.returned_val orelse .null;
                            }
                            if (res) |rv| last_val = rv;
                        }
                    }
                } else if (f.captures.len == 0) {
                    var iters: usize = 0;
                    while (true) {
                        iters += 1;
                        if (iters > state.comptime_max_loop_iterations) {
                            return compile_errors.compileFailFmt(state, "comptime loop exceeded maximum iteration limit of {d}", .{state.comptime_max_loop_iterations});
                        }
                        const cond_val = (try evalExpr(state, &bscope, f.expr)) orelse
                            return compile_errors.compileFailFmt(state, "for loop condition must be constant in comptime", .{});
                        if (!cond_val.isTruthy()) break;

                        var loop_scope = ComptimeScope.initLoop(state.allocator, &bscope);
                        defer loop_scope.deinit();

                        if (f.body.* == .block) {
                            const res = try evalComptimeBlock(state, &loop_scope, &f.body.block);
                            if (loop_scope.has_broken) {
                                if (loop_scope.broken_val) |bv| last_val = bv;
                                break;
                            }
                            if (loop_scope.has_returned) {
                                bscope.has_returned = true;
                                bscope.returned_val = loop_scope.returned_val;
                                return loop_scope.returned_val orelse .null;
                            }
                            if (res) |rv| last_val = rv;
                        }
                    }
                } else {
                    const first_val = (try evalExpr(state, &bscope, f.expr)) orelse
                        return compile_errors.compileFailFmt(state, "for loop expression must be constant in comptime", .{});

                    switch (first_val) {
                        .array => |a_obj| {
                            var iters: usize = 0;
                            for (a_obj.elements.items, 0..) |item, idx| {
                                iters += 1;
                                if (iters > state.comptime_max_loop_iterations) {
                                    return compile_errors.compileFailFmt(state, "comptime loop exceeded maximum iteration limit of {d}", .{state.comptime_max_loop_iterations});
                                }
                                var loop_scope = ComptimeScope.initLoop(state.allocator, &bscope);
                                defer loop_scope.deinit();

                                try loop_scope.put(f.captures[0].name, item);
                                if (f.captures.len > 1) {
                                    try loop_scope.put(f.captures[1].name, .{ .i64 = @intCast(idx) });
                                }

                                if (f.body.* == .block) {
                                    const res = try evalComptimeBlock(state, &loop_scope, &f.body.block);
                                    if (loop_scope.has_broken) {
                                        if (loop_scope.broken_val) |bv| last_val = bv;
                                        break;
                                    }
                                    if (loop_scope.has_returned) {
                                        bscope.has_returned = true;
                                        bscope.returned_val = loop_scope.returned_val;
                                        return loop_scope.returned_val orelse .null;
                                    }
                                    if (res) |rv| last_val = rv;
                                }
                            }
                        },
                        .tuple => |t_obj| {
                            var iters: usize = 0;
                            for (t_obj, 0..) |item, idx| {
                                iters += 1;
                                if (iters > state.comptime_max_loop_iterations) {
                                    return compile_errors.compileFailFmt(state, "comptime loop exceeded maximum iteration limit of {d}", .{state.comptime_max_loop_iterations});
                                }
                                var loop_scope = ComptimeScope.initLoop(state.allocator, &bscope);
                                defer loop_scope.deinit();

                                try loop_scope.put(f.captures[0].name, item);
                                if (f.captures.len > 1) {
                                    try loop_scope.put(f.captures[1].name, .{ .i64 = @intCast(idx) });
                                }

                                if (f.body.* == .block) {
                                    const res = try evalComptimeBlock(state, &loop_scope, &f.body.block);
                                    if (loop_scope.has_broken) {
                                        if (loop_scope.broken_val) |bv| last_val = bv;
                                        break;
                                    }
                                    if (loop_scope.has_returned) {
                                        bscope.has_returned = true;
                                        bscope.returned_val = loop_scope.returned_val;
                                        return loop_scope.returned_val orelse .null;
                                    }
                                    if (res) |rv| last_val = rv;
                                }
                            }
                        },
                        .string => |s_obj| {
                            var iters: usize = 0;
                            for (s_obj, 0..) |byte, idx| {
                                iters += 1;
                                if (iters > state.comptime_max_loop_iterations) {
                                    return compile_errors.compileFailFmt(state, "comptime loop exceeded maximum iteration limit of {d}", .{state.comptime_max_loop_iterations});
                                }
                                var loop_scope = ComptimeScope.initLoop(state.allocator, &bscope);
                                defer loop_scope.deinit();

                                try loop_scope.put(f.captures[0].name, .{ .i64 = @intCast(byte) });
                                if (f.captures.len > 1) {
                                    try loop_scope.put(f.captures[1].name, .{ .i64 = @intCast(idx) });
                                }

                                if (f.body.* == .block) {
                                    const res = try evalComptimeBlock(state, &loop_scope, &f.body.block);
                                    if (loop_scope.has_broken) {
                                        if (loop_scope.broken_val) |bv| last_val = bv;
                                        break;
                                    }
                                    if (loop_scope.has_returned) {
                                        bscope.has_returned = true;
                                        bscope.returned_val = loop_scope.returned_val;
                                        return loop_scope.returned_val orelse .null;
                                    }
                                    if (res) |rv| last_val = rv;
                                }
                            }
                        },
                        else => {
                            var cur_val = first_val;
                            var iters: usize = 0;
                            while (cur_val != .null and cur_val.isTruthy()) {
                                iters += 1;
                                if (iters > state.comptime_max_loop_iterations) {
                                    return compile_errors.compileFailFmt(state, "comptime loop exceeded maximum iteration limit of {d}", .{state.comptime_max_loop_iterations});
                                }
                                var loop_scope = ComptimeScope.initLoop(state.allocator, &bscope);
                                defer loop_scope.deinit();

                                try loop_scope.put(f.captures[0].name, cur_val);

                                if (f.body.* == .block) {
                                    const res = try evalComptimeBlock(state, &loop_scope, &f.body.block);
                                    if (loop_scope.has_broken) {
                                        if (loop_scope.broken_val) |bv| last_val = bv;
                                        break;
                                    }
                                    if (loop_scope.has_returned) {
                                        bscope.has_returned = true;
                                        bscope.returned_val = loop_scope.returned_val;
                                        return loop_scope.returned_val orelse .null;
                                    }
                                    if (res) |rv| last_val = rv;
                                }
                                const next_val = (try evalExpr(state, &bscope, f.expr)) orelse break;
                                cur_val = next_val;
                            }
                        },
                    }
                }
            },
            .if_expr => |ife| {
                const cond_val = (try evalExpr(state, &bscope, ife.condition)) orelse return compile_errors.compileFailFmt(state, "if condition must be constant in comptime", .{});
                if (cond_val.isTruthy()) {
                    if (ife.body.* == .block) {
                        last_val = (try evalComptimeBlock(state, &bscope, &ife.body.block)) orelse return null;
                    } else {
                        last_val = (try evalExpr(state, &bscope, ife.body)) orelse return null;
                    }
                } else if (ife.else_body) |elb| {
                    if (elb.* == .block) {
                        last_val = (try evalComptimeBlock(state, &bscope, &elb.block)) orelse return null;
                    } else {
                        last_val = (try evalExpr(state, &bscope, elb)) orelse return null;
                    }
                }
                if (bscope.has_broken) return bscope.broken_val orelse last_val;
                if (bscope.has_returned) return bscope.returned_val orelse last_val;
            },
            .switch_expr => |sw| {
                const cond_val = (try evalExpr(state, &bscope, sw.condition)) orelse
                    return compile_errors.compileFailFmt(state, "switch condition must be constant in comptime", .{});
                for (sw.prongs) |prong| {
                    var is_match = prong.is_else;
                    if (!is_match) {
                        for (prong.patterns) |pat| {
                            const pv = (try evalExpr(state, &bscope, pat)) orelse continue;
                            if (constValueEql(cond_val, pv)) {
                                is_match = true;
                                break;
                            }
                        }
                    }
                    if (!is_match) continue;

                    var prong_scope = ComptimeScope.init(state.allocator, &bscope);
                    defer prong_scope.deinit();
                    const res: ?ConstValue = if (prong.body.* == .block)
                        try evalComptimeBlock(state, &prong_scope, &prong.body.block)
                    else
                        try evalExpr(state, &prong_scope, prong.body);

                    if (prong_scope.has_returned) {
                        bscope.has_returned = true;
                        bscope.returned_val = prong_scope.returned_val;
                        return prong_scope.returned_val orelse .null;
                    }
                    if (prong_scope.has_broken) {
                        last_val = prong_scope.broken_val orelse (res orelse last_val);
                    } else if (res) |rv| {
                        last_val = rv;
                    }
                    break;
                }
            },
            .continue_expr => {
                bscope.has_continued = true;
                return last_val;
            },
            .break_expr => |brk| {
                if (brk.value) |bv| {
                    const v = (try evalExpr(state, &bscope, bv)) orelse return null;
                    bscope.has_broken = true;
                    bscope.broken_val = v;
                    return v;
                }
                bscope.has_broken = true;
                return last_val;
            },
            .return_expr => |ret| {
                if (ret.return_value) |rv| {
                    const v = (try evalExpr(state, &bscope, rv)) orelse return null;
                    bscope.has_returned = true;
                    bscope.returned_val = v;
                    return v;
                }
                bscope.has_returned = true;
                return .null;
            },
            else => {
                if (try evalExpr(state, &bscope, stmt_node)) |ev| {
                    last_val = ev;
                }
            },
        }
    }

    return last_val;
}

pub fn evalComptimeCall(state: *CompilerState, scope: ?*ComptimeScope, call: *const ast.Call) anyerror!?ConstValue {
    var fn_name: []const u8 = undefined;
    var self_val: ?ConstValue = null;

    if (call.callee.* == .primary) {
        fn_name = call.callee.primary.name;
    } else if (call.callee.* == .member and call.callee.member.property.* == .primary) {
        const prop_name = call.callee.member.property.primary.name;
        if (call.callee.member.object.* == .primary and state.structs.contains(call.callee.member.object.primary.name)) {
            const sname = call.callee.member.object.primary.name;
            fn_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ sname, prop_name });
        } else {
            const obj_val = (try evalExpr(state, scope, call.callee.member.object)) orelse return null;
            if (obj_val == .struct_val) {
                self_val = obj_val;
                fn_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ obj_val.struct_val.type_name, prop_name });
            } else {
                return null;
            }
        }
    } else {
        return null;
    }

    const fn_def = state.functions.get(fn_name) orelse return null;
    if (fn_def.node.* != .function_decl) return null;
    const fdecl = fn_def.node.function_decl;

    var call_scope = ComptimeScope.init(state.allocator, null);
    defer call_scope.deinit();

    // Bind parameters
    const plist: []ast.Param = if (fdecl.params.* == .params) fdecl.params.params.params else &.{};
    var arg_idx: usize = 0;
    for (plist, 0..) |p, i| {
        if (i == 0 and self_val != null and (std.mem.eql(u8, p.name, "self") or std.mem.eql(u8, p.name, "this"))) {
            try call_scope.put(p.name, self_val.?);
        } else if (arg_idx < call.args.len) {
            const arg_val = (try evalExpr(state, scope, call.args[arg_idx])) orelse return null;
            try call_scope.put(p.name, arg_val);
            arg_idx += 1;
        } else {
            try call_scope.put(p.name, .null);
        }
    }

    if (fdecl.body.* == .block) {
        const res = try evalComptimeBlock(state, &call_scope, &fdecl.body.block);
        if (call_scope.has_returned) return call_scope.returned_val orelse .null;
        return res;
    }
    return try evalExpr(state, &call_scope, fdecl.body);
}

/// Lower a fully-evaluated compile-time value into bytecode, leaving exactly one
/// runtime value on the stack. Allocations honour `state.alloc_immortal` so
/// module-level constants live on the immortal heap.
fn emitArrayValue(state: *CompilerState, elems: []const ConstValue) anyerror!void {
    const alloc = if (state.alloc_immortal) "__allocImmortalArray" else "__allocArray";
    try emit.emitNameGet(state, .OP_GET_GLOBAL, alloc);
    try emit.emitConstant(state, .{ .i64 = @intCast(elems.len) });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    for (elems, 0..) |el, i| {
        try emit.emitOp(state, .OP_DUP);
        try emit.emitConstant(state, .{ .i64 = @intCast(i) });
        try emitConstValue(state, el);
        try emit.emitOp(state, .OP_SET_ARRAY);
        try emit.emitOp(state, .OP_POP);
    }
}

fn emitStructValue(state: *CompilerState, s: *ConstStruct) anyerror!void {
    const sd = state.structs.get(s.type_name) orelse {
        return compile_errors.compileFailFmt(state, "cannot emit value of unknown comptime struct type '{s}'", .{s.type_name});
    };
    const alloc = if (state.alloc_immortal) "__allocImmortalBytes" else "__allocBytes";
    try emit.emitNameGet(state, .OP_GET_GLOBAL, alloc);
    try emit.emitConstant(state, .{ .i64 = sd.size });
    try emit.emitOp(state, .OP_CALL);
    try emit.emitByte(state, 1);
    var it = s.fields.iterator();
    while (it.next()) |entry| {
        const offset = sd.offsets.get(entry.key_ptr.*) orelse continue;
        const fty = sd.types.get(entry.key_ptr.*) orelse "int";
        const kind: u8 = @intFromEnum(layout.fieldKind(state, fty));
        try emit.emitOp(state, .OP_DUP);
        try emitConstValue(state, entry.value_ptr.*);
        try emit.emitStoreField(state, offset, kind);
        try emit.emitOp(state, .OP_POP);
    }
}

/// Recursively release heap owned by a `ConstValue`. Strings and `type_name`s are
/// borrowed from the AST (or immortal compiler state) and are intentionally not freed.
pub fn deinitConstValue(v: ConstValue, allocator: std.mem.Allocator) void {
    switch (v) {
        .array => |a| {
            for (a.elements.items) |el| deinitConstValue(el, allocator);
            a.deinit();
            allocator.destroy(a);
        },
        .tuple => |t| {
            for (t) |el| deinitConstValue(el, allocator);
            allocator.free(t);
        },
        .struct_val => |s| {
            var it = s.fields.valueIterator();
            while (it.next()) |vp| deinitConstValue(vp.*, allocator);
            s.deinit();
            allocator.destroy(s);
        },
        else => {},
    }
}

pub fn emitConstValue(state: *CompilerState, v: ConstValue) anyerror!void {
    switch (v) {
        .null => try emit.emitOp(state, .OP_NULL),
        .bool => |b| try emit.emitOp(state, if (b) .OP_TRUE else .OP_FALSE),
        .i64 => |n| try emit.emitConstant(state, .{ .i64 = n }),
        .f64 => |f| try emit.emitConstant(state, .{ .f64 = f }),
        .string => |s| try emit.emitString(state, s),
        .enum_variant => |ev| try emit.emitConstant(state, .{ .i64 = ev.tag }),
        .array => |a| try emitArrayValue(state, a.elements.items),
        .tuple => |t| try emitArrayValue(state, t),
        .struct_val => |s| try emitStructValue(state, s),
    }
}
