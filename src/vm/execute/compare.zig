const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const OpCode = @import("../../bytecode/opcode.zig").OpCode;
const Value = state_mod.Value;
const VMState = state_mod.VMState;

pub const CmpError = error{ RuntimeError, TypeError, OutOfMemory };

fn fail(msg: []const u8) CmpError {
    @import("std").debug.print("RuntimeError: {s}\n", .{msg});
    return error.RuntimeError;
}

pub fn compareEq(vm: *VMState, invert: bool) CmpError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const eq = valuesEqual(vm, a, b);
    try stack.push(vm, .{ .bool = if (invert) !eq else eq });
}

fn valuesEqual(vm: *VMState, a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| switch (b) {
            .bool => |y| x == y,
            else => false,
        },
        .int => |x| switch (b) {
            .int => |y| x == y,
            .ptr => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .int => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .ptr, .name, .slice => switch (b) {
            .ptr, .name, .slice => blk: {
                if (a == .ptr and isErrorPtr(vm, a.ptr)) break :blk if (b == .ptr) a.ptr == b.ptr else false;
                if (b == .ptr and isErrorPtr(vm, b.ptr)) break :blk false;
                break :blk @import("../builtins/util.zig").stringEquals(vm, a, b);
            },
            .int => |y| if (a == .ptr) a.ptr == y else false,
            else => false,
        },
        else => false,
    };
}

fn isErrorPtr(vm: *VMState, p: i32) bool {
    if (p < 1 or p - 1 >= vm.heap_ptr) return false;
    const tag = vm.memory[@intCast(p - 1)];
    return tag == .int and tag.int == state_mod.ERROR_TAG;
}

pub fn compareOrd(vm: *VMState, op: OpCode) CmpError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const ai = asOrdInt(a) orelse return fail("Operands must be numbers");
    const bi = asOrdInt(b) orelse return fail("Operands must be numbers");
    const result = switch (op) {
        .OP_LESS => ai < bi,
        .OP_LESS_EQUAL => ai <= bi,
        .OP_GREATER => ai > bi,
        .OP_GREATER_EQUAL => ai >= bi,
        else => unreachable,
    };
    try stack.push(vm, .{ .bool = result });
}

fn asOrdInt(v: Value) ?i32 {
    return switch (v) {
        .int => |n| n,
        .ptr => |p| p,
        .bool => |b| @intFromBool(b),
        .float => |n| @intFromFloat(n),
        else => null,
    };
}
