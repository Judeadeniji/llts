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
const runtime = @import("../../errors/runtime.zig");
const widths = @import("../../compiler/widths.zig");

const OpCode = opcode.OpCode;
const VMState = state_mod.VMState;
const Value = state_mod.Value;

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

fn readByte(code_ptr: [*]const u8, ip: *usize) u8 {
    const b = code_ptr[ip.*];
    ip.* += 1;
    return b;
}

fn readShort(code_ptr: [*]const u8, ip: *usize) u16 {
    const hi: u16 = code_ptr[ip.*];
    ip.* += 1;
    const lo: u16 = code_ptr[ip.*];
    ip.* += 1;
    return (@as(u16, hi) << 8) | lo;
}

pub fn execute(vm: *VMState, start_ip: usize) RuntimeError!void {
    var ip: usize = start_ip;
    const code = vm.chunk.code.items;
    // Guard against infinite loops so the process always exits promptly.
    var steps: u64 = 0;
    const max_steps: comptime_int = 50_000_000;

    while (ip < code.len) {
        const op: OpCode = @enumFromInt(readByte(code.ptr, &ip));
        switch (op) {
            .OP_LINE => {
                const line_no = readShort(code.ptr, &ip);
                const col = readShort(code.ptr, &ip);
                debug_ops.line(vm, line_no, col);
            },
            .OP_SOURCE => debug_ops.source(vm, readShort(code.ptr, &ip)),
            .OP_CONSTANT => try stack.push(vm, vm.chunk.constants.items[readShort(code.ptr, &ip)]),
            .OP_NULL => try stack.push(vm, .null),
            .OP_TRUE => try stack.push(vm, Value.fromBool(true)),
            .OP_FALSE => try stack.push(vm, Value.fromBool(false)),
            .OP_POP => {
                _ = stack.pop(vm);
            },
            .OP_DUP => try stack.push(vm, stack.peek(vm, 0)),
            .OP_PRINT => print_builtin.printArgs(vm, readByte(code.ptr, &ip)) catch return error.RuntimeError,
            .OP_ADD, .OP_SUB, .OP_MUL, .OP_DIV, .OP_MOD, .OP_POW => try arith.binArith(vm, op),
            .OP_BIT_AND, .OP_BIT_OR, .OP_BIT_XOR, .OP_SHL, .OP_SHR => try arith.binBitwise(vm, op),
            .OP_NEGATE => try arith.negate(vm),
            .OP_NOT => try arith.not_(vm),
            .OP_BIT_NOT => try arith.bitNot(vm),
            .OP_EQUAL => try compare.compareEq(vm, false),
            .OP_NOT_EQUAL => try compare.compareEq(vm, true),
            .OP_LESS, .OP_LESS_EQUAL, .OP_GREATER, .OP_GREATER_EQUAL => try compare.compareOrd(vm, op),
            .OP_JUMP => control.jump(&ip, readShort(code.ptr, &ip)),
            .OP_JUMP_IF_FALSE => control.jumpIfFalse(vm, &ip, readShort(code.ptr, &ip)),
            .OP_LOOP => {
                steps += 1;
                if (steps & 1023 == 0 and steps > max_steps) return error.RuntimeError;
                control.loop(&ip, readShort(code.ptr, &ip));
            },
            .OP_FOR_PREP => {
                const i_slot = readByte(code.ptr, &ip);
                const end_slot = readByte(code.ptr, &ip);
                const skip = readShort(code.ptr, &ip);
                control.forPrep(vm, &ip, i_slot, end_slot, skip) catch return error.TypeError;
            },
            .OP_FOR_LOOP => {
                steps += 1;
                if (steps & 1023 == 0 and steps > max_steps) return error.RuntimeError;
                const i_slot = readByte(code.ptr, &ip);
                const end_slot = readByte(code.ptr, &ip);
                const back = readShort(code.ptr, &ip);
                control.forLoop(vm, &ip, i_slot, end_slot, back) catch return error.TypeError;
            },
            .OP_ADD_TYPED => try arith.binArithTyped(vm, .add, readByte(code.ptr, &ip)),
            .OP_SUB_TYPED => try arith.binArithTyped(vm, .sub, readByte(code.ptr, &ip)),
            .OP_MUL_TYPED => try arith.binArithTyped(vm, .mul, readByte(code.ptr, &ip)),
            .OP_LT_TYPED => try arith.ltTyped(vm, readByte(code.ptr, &ip)),
            .OP_RETURN => {
                if (try call.doReturn(vm, &ip)) return;
            },
            .OP_GET_LOCAL => try vars.getLocal(vm, readByte(code.ptr, &ip)),
            .OP_SET_LOCAL => try vars.setLocal(vm, readByte(code.ptr, &ip)),
            .OP_GET_GLOBAL => try vars.getGlobal(vm, readShort(code.ptr, &ip)),
            .OP_SET_GLOBAL => try vars.setGlobal(vm, readShort(code.ptr, &ip)),
            .OP_GET_FUNCTION => try vars.getFunction(vm, readShort(code.ptr, &ip)),
            .OP_CALL => {
                steps += 1;
                if (steps & 1023 == 0 and steps > max_steps) return error.RuntimeError;
                try call.callDynamic(vm, &ip, readByte(code.ptr, &ip));
            },
            .OP_CALL_STATIC => {
                const addr = readShort(code.ptr, &ip);
                const argc = readByte(code.ptr, &ip);
                try call.callStatic(vm, &ip, addr, argc);
            },
            .OP_PACK_REST => try call.packRest(vm, readByte(code.ptr, &ip)),
            .OP_MAKE_STRING => try heap.makeString(vm),
            .OP_MAKE_ERROR => try heap.makeError(vm),
            .OP_MAKE_ERROR_PAYLOAD => try heap.makeErrorPayload(vm),
            .OP_IS_ERROR => try heap.isError(vm),
            .OP_ERROR_NAME => try heap.errorName(vm),
            .OP_STRING_ADD => try heap.stringAdd(vm),
            .OP_GET_INDEX => try heap.getIndex(vm),
            .OP_SET_INDEX => try heap.setIndex(vm),
            .OP_LOAD_FIELD => {
                const off = readShort(code.ptr, &ip);
                const kind = readByte(code.ptr, &ip);
                try heap.loadField(vm, off, kind);
            },
            .OP_STORE_FIELD => {
                const off = readShort(code.ptr, &ip);
                const kind = readByte(code.ptr, &ip);
                try heap.storeField(vm, off, kind);
            },
            .OP_GET_ARRAY => try heap.getArray(vm),
            .OP_SET_ARRAY => try heap.setArray(vm),
            .OP_SLICE => try heap.sliceView(vm),
            .OP_MARK_CONST => try debug_ops.markConst(vm, readByte(code.ptr, &ip)),
            .OP_ASSERT_TYPE => try debug_ops.assertType(vm, readByte(code.ptr, &ip)),
            .OP_SIZEOF => {
                const val = stack.pop(vm);
                const size: i64 = switch (val) {
                    .null => 0,
                    .u1 => 1,
                    .i8, .u8 => 1,
                    .i16, .u16 => 2,
                    .i32, .u32, .f32 => 4,
                    .i64, .u64, .f64 => 8,
                    .ptr => 4,
                    .slice => 8,
                    .bytes => |b| b.len,
                    .array => |a| @as(i64, a.count) * @as(i64, @intCast(state_mod.VMState.value_size)),
                    .name => 4,
                    .native, .function, .module, .list, .map, .buffer => 8,
                };
                try stack.push(vm, .{ .i64 = size });
            },
            .OP_AS => {
                const kind = readByte(code.ptr, &ip);
                const w: widths.Width = @enumFromInt(kind);
                const top = stack.peek(vm, 0);
                if (top == .i64 and (w == .i64 or w == .isize)) {
                    // Fast path: already i64 on stack top, no-op
                } else if (top == .f64 and (w == .f64 or w == .fsize)) {
                    // Fast path: already f64 on stack top, no-op
                } else {
                    const val = stack.pop(vm);
                    const out = widths.castValue(val, w) catch |err| switch (err) {
                        error.OutOfRange => return runtime.runtimeFail(vm, "@as: value out of range for target width"),
                        else => return error.RuntimeError,
                    };
                    try stack.push(vm, out);
                }
            },
            .OP_STRING_EQUAL, .OP_STRING_NOT_EQUAL => try compare.compareEq(vm, op == .OP_STRING_NOT_EQUAL),
            .OP_IMPORT => {
                _ = readShort(code.ptr, &ip);
            },
            .OP_GET_PROPERTY => try getProperty(vm, readShort(code.ptr, &ip)),
            .OP_SET_PROPERTY => try setProperty(vm, readShort(code.ptr, &ip)),
            .OP_GET_MODULE => {
                const name_val = vm.chunk.constants.items[readShort(code.ptr, &ip)];
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

fn getProperty(vm: *VMState, const_idx: u16) RuntimeError!void {
    const name_val = vm.chunk.constants.items[const_idx];
    const name = vm.chunk.stringAt(switch (name_val) {
        .name => |i| i,
        else => return error.RuntimeError,
    });
    const obj = stack.pop(vm);
    // error.message → heap slot at ptr
    if (std.mem.eql(u8, name, "message") or std.mem.eql(u8, name, "code")) {
        switch (obj) {
            .ptr => |p| {
                const tag = vm.slot(p - 1).*;
                if (tag == .i64 and tag.i64 == state_mod.ERROR_TAG) {
                    try stack.push(vm, vm.slot(p).*);
                    return;
                }
            },
            else => {},
        }
    }
    if (std.mem.eql(u8, name, "payload")) {
        switch (obj) {
            .ptr => |p| {
                const tag = vm.slot(p - 1).*;
                if (tag == .i64 and tag.i64 == state_mod.ERROR_TAG) {
                    try stack.push(vm, vm.slot(p + 1).*);
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
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Undefined property '{s}'", .{name}) catch "Undefined property";
        return runtime.runtimeFail(vm, msg);
    }
    // Struct field access uses numeric offsets via GET_INDEX at compile time;
    // dynamic property falls through to undefined.
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Undefined property '{s}'", .{name}) catch "Undefined property";
    return runtime.runtimeFail(vm, msg);
}

fn setProperty(vm: *VMState, const_idx: u16) RuntimeError!void {
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
