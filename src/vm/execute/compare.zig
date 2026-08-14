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
        .ptr, .name, .slice, .bytes => switch (b) {
            .ptr, .name, .slice, .bytes => blk: {
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
    if (p < 1 or !vm.isValidHeapPtr(p - 1)) return false;
    const tag = vm.memory[@intCast(p - 1)];
    return tag == .int and tag.int == state_mod.ERROR_TAG;
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
    try stack.push(vm, .{ .bool = result });
}

fn asOrdFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .ptr => |p| @floatFromInt(p),
        .bool => |b| @floatFromInt(@intFromBool(b)),
        .float => |n| n,
        else => null,
    };
}
