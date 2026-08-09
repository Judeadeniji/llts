const std = @import("std");
const opcode = @import("../../bytecode/opcode.zig");
const state_mod = @import("../state.zig");
const stack = @import("../stack.zig");
const print_builtin = @import("../builtins/print.zig");
const arith = @import("arith.zig");
const compare = @import("compare.zig");
const vars = @import("vars.zig");
const control = @import("control.zig");
const call = @import("call.zig");
const heap = @import("heap.zig");
const debug_ops = @import("debug.zig");

const OpCode = opcode.OpCode;
const VMState = state_mod.VMState;

pub const RuntimeError = error{
    RuntimeError,
    StackUnderflow,
    OutOfMemory,
    TypeError,
    IndexOutOfBounds,
    ConstMutation,
    TooManyFrames,
    ArityError,
    NoSpaceLeft,
};

fn readByte(vm: *VMState, ip: *usize) u8 {
    const b = vm.chunk.code.items[ip.*];
    ip.* += 1;
    return b;
}

fn readShort(vm: *VMState, ip: *usize) u16 {
    const hi: u16 = readByte(vm, ip);
    const lo: u16 = readByte(vm, ip);
    return (hi << 8) | lo;
}

pub fn execute(vm: *VMState, start_ip: usize) RuntimeError!void {
    var ip: usize = start_ip;
    const code = vm.chunk.code.items;
    // Guard against infinite loops so the process always exits promptly.
    var steps: u64 = 0;
    const max_steps: u64 = 2_000_000;

    while (ip < code.len) {
        steps += 1;
        if (steps > max_steps) {
            std.debug.print("RuntimeError: instruction limit exceeded ({d})\n", .{max_steps});
            return error.RuntimeError;
        }
        const op: OpCode = @enumFromInt(readByte(vm, &ip));
        switch (op) {
            .OP_LINE => debug_ops.line(vm, readShort(vm, &ip)),
            .OP_CONSTANT => try stack.push(vm, vm.chunk.constants.items[readByte(vm, &ip)]),
            .OP_NULL => try stack.push(vm, .null),
            .OP_TRUE => try stack.push(vm, .{ .bool = true }),
            .OP_FALSE => try stack.push(vm, .{ .bool = false }),
            .OP_POP => {
                _ = stack.pop(vm);
            },
            .OP_DUP => try stack.push(vm, stack.peek(vm, 0)),
            .OP_PRINT => print_builtin.printArgs(vm, readByte(vm, &ip)) catch return error.RuntimeError,
            .OP_ADD, .OP_SUB, .OP_MUL, .OP_DIV, .OP_MOD, .OP_POW => try arith.binArith(vm, op),
            .OP_NEGATE => try arith.negate(vm),
            .OP_NOT => try arith.not_(vm),
            .OP_EQUAL => try compare.compareEq(vm, false),
            .OP_NOT_EQUAL => try compare.compareEq(vm, true),
            .OP_LESS, .OP_LESS_EQUAL, .OP_GREATER, .OP_GREATER_EQUAL => try compare.compareOrd(vm, op),
            .OP_JUMP => control.jump(&ip, readShort(vm, &ip)),
            .OP_JUMP_IF_FALSE => control.jumpIfFalse(vm, &ip, readShort(vm, &ip)),
            .OP_LOOP => control.loop(&ip, readShort(vm, &ip)),
            .OP_RETURN => {
                if (try call.doReturn(vm, &ip)) return;
            },
            .OP_GET_LOCAL => try vars.getLocal(vm, readByte(vm, &ip)),
            .OP_SET_LOCAL => try vars.setLocal(vm, readByte(vm, &ip)),
            .OP_GET_GLOBAL => try vars.getGlobal(vm, readByte(vm, &ip)),
            .OP_SET_GLOBAL => try vars.setGlobal(vm, readByte(vm, &ip)),
            .OP_GET_FUNCTION => try vars.getFunction(vm, readByte(vm, &ip)),
            .OP_CALL => try call.callDynamic(vm, &ip, readByte(vm, &ip)),
            .OP_CALL_STATIC => {
                const addr = readShort(vm, &ip);
                const argc = readByte(vm, &ip);
                try call.callStatic(vm, &ip, addr, argc);
            },
            .OP_PACK_REST => try call.packRest(vm, readByte(vm, &ip)),
            .OP_MAKE_STRING => try heap.makeString(vm),
            .OP_MAKE_ERROR => try heap.makeError(vm),
            .OP_IS_ERROR => try heap.isError(vm),
            .OP_STRING_ADD => try heap.stringAdd(vm),
            .OP_GET_INDEX => try heap.getIndex(vm),
            .OP_SET_INDEX => try heap.setIndex(vm),
            .OP_GET_ARRAY => try heap.getArray(vm),
            .OP_SET_ARRAY => try heap.setArray(vm),
            .OP_MARK_CONST => try debug_ops.markConst(vm, readByte(vm, &ip)),
            .OP_ASSERT_TYPE => try debug_ops.assertType(vm, readByte(vm, &ip)),
            .OP_STRING_EQUAL, .OP_STRING_NOT_EQUAL => try compare.compareEq(vm, op == .OP_STRING_NOT_EQUAL),
            .OP_IMPORT => {
                _ = readByte(vm, &ip);
            },
            .OP_GET_PROPERTY => try getProperty(vm, readByte(vm, &ip)),
            .OP_SET_PROPERTY => try setProperty(vm, readByte(vm, &ip)),
            .OP_GET_MODULE => {
                const name_val = vm.chunk.constants.items[readByte(vm, &ip)];
                const module_name = switch (name_val) {
                    .name => |i| vm.chunk.stringAt(i),
                    else => return error.RuntimeError,
                };
                const mod = try vm.allocModule(module_name);
                try stack.push(vm, .{ .module = mod });
            },
        }
    }
}

fn getProperty(vm: *VMState, const_idx: u8) RuntimeError!void {
    const name = vm.chunk.stringAt(switch (vm.chunk.constants.items[const_idx]) {
        .name => |i| i,
        else => return error.RuntimeError,
    });
    const obj = stack.pop(vm);
    // error.message → heap slot at ptr
    if (std.mem.eql(u8, name, "message")) {
        switch (obj) {
            .ptr => |p| {
                if (vm.memory[@intCast(p - 1)] == state_mod.ERROR_TAG) {
                    try stack.push(vm, .{ .ptr = vm.memory[@intCast(p)] });
                    return;
                }
            },
            else => {},
        }
    }
    if (obj == .module) {
        if (obj.module.props.get(name)) |v| {
            try stack.push(vm, v);
            return;
        }
        std.debug.print("RuntimeError: Undefined property '{s}'\n", .{name});
        return error.RuntimeError;
    }
    // Struct field access uses numeric offsets via GET_INDEX at compile time;
    // dynamic property falls through to undefined.
    std.debug.print("RuntimeError: Undefined property '{s}'\n", .{name});
    return error.RuntimeError;
}

fn setProperty(vm: *VMState, const_idx: u8) RuntimeError!void {
    const name = vm.chunk.stringAt(switch (vm.chunk.constants.items[const_idx]) {
        .name => |i| i,
        else => return error.RuntimeError,
    });
    const val = stack.pop(vm);
    const obj = stack.pop(vm);
    if (obj == .module) {
        const gop = try obj.module.props.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try vm.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = val;
        try stack.push(vm, val);
        return;
    }
    try stack.push(vm, val);
}
