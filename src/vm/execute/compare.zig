const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const runtime = @import("../../errors/runtime.zig");
const OpCode = @import("../../bytecode/opcode.zig").OpCode;
const Value = state_mod.Value;
const VMState = state_mod.VMState;

pub const CmpError = error{ RuntimeError, TypeError, OutOfMemory };

fn fail(vm: *VMState, msg: []const u8) CmpError {
    return runtime.runtimeFail(vm, msg);
}

pub fn compareEq(vm: *VMState, invert: bool) CmpError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const eq = valuesEqual(vm, a, b);
    try stack.push(vm, Value.fromBool(if (invert) !eq else eq ));
}

fn valuesEqual(vm: *VMState, a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .u1 => |x| switch (b) {
            .u1 => |y| x == y,
            else => false,
        },
        .i64 => |x| switch (b) {
            .i64 => |y| x == y,
            .u8 => |y| x == y,
            .ptr => |y| x == y,
            .f32 => |y| @as(f64, @floatFromInt(x)) == @as(f64, y),
            .f64 => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .u8 => |x| switch (b) {
            .u8 => |y| x == y,
            .i64 => |y| x == y,
            .f32 => |y| @as(f64, @floatFromInt(x)) == @as(f64, y),
            .f64 => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .f64 => |x| switch (b) {
            .f64 => |y| x == y,
            .f32 => |y| x == @as(f64, y),
            .i64 => |y| x == @as(f64, @floatFromInt(y)),
            .u8 => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .f32 => |x| switch (b) {
            .f32 => |y| x == y,
            .f64 => |y| @as(f64, x) == y,
            .i64 => |y| @as(f64, x) == @as(f64, @floatFromInt(y)),
            .u8 => |y| @as(f64, x) == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .ptr, .name, .slice, .bytes => switch (b) {
            .ptr, .name, .slice, .bytes => blk: {
                if (a == .ptr and isErrorPtr(vm, a.ptr)) break :blk if (b == .ptr) a.ptr == b.ptr else false;
                if (b == .ptr and isErrorPtr(vm, b.ptr)) break :blk false;
                break :blk @import("../builtins/util.zig").stringEquals(vm, a, b);
            },
            .i64 => |y| if (a == .ptr) a.ptr == y else false,
            else => false,
        },
        else => false,
    };
}

fn isErrorPtr(vm: *VMState, p: i32) bool {
    if (p < 1 or !vm.isValidHeapPtr(p - 1)) return false;
    const tag = vm.slot(p - 1).*;
    return tag == .i64 and tag.i64 == state_mod.ERROR_TAG;
}

pub fn compareOrd(vm: *VMState, op: OpCode) CmpError!void {
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const af = asOrdFloat(a) orelse return fail(vm, "Operands must be numbers");
    const bf = asOrdFloat(b) orelse return fail(vm, "Operands must be numbers");
    const result = switch (op) {
        .OP_LESS => af < bf,
        .OP_LESS_EQUAL => af <= bf,
        .OP_GREATER => af > bf,
        .OP_GREATER_EQUAL => af >= bf,
        else => unreachable,
    };
    try stack.push(vm, Value.fromBool(result ));
}

fn asOrdFloat(v: Value) ?f64 {
    return switch (v) {
        .i64 => |n| @floatFromInt(n),
        .u8 => |n| @floatFromInt(n),
        .f32 => |n| n,
        .f64 => |n| n,
        .ptr => |p| @floatFromInt(p),
        .u1 => |b| @floatFromInt(b),
        else => null,
    };
}
