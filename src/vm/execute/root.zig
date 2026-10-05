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
    const s = std.mem.readInt(u16, code_ptr[ip.*..][0..2], .big);
    ip.* += 2;
    return s;
}

inline fn syncVM(vm: *VMState, current_sp: usize) void {
    vm.sp = current_sp;
}

pub fn execute(vm: *VMState, start_ip: usize) RuntimeError!void {
    var ip: usize = start_ip;
    const code = vm.chunk.code.items;
    const code_ptr = code.ptr;
    const code_len = code.len;

    var sp: usize = vm.sp;
    const stack_buf = vm.stack_buf.ptr;
    const globals = vm.global_values.ptr;
    const global_count = vm.global_count;
    const constants = vm.chunk.constants.items.ptr;

    var base_slot: usize = if (vm.frame_count > 0) vm.frames[vm.frame_count - 1].base_slot else 0;
    var cur_frame: *state_mod.CallFrame = if (vm.frame_count > 0) &vm.frames[vm.frame_count - 1] else undefined;

    errdefer syncVM(vm, sp);

    while (ip < code_len) {
        const op: OpCode = @enumFromInt(code_ptr[ip]);
        ip += 1;
        switch (op) {
            .OP_LINE => {
                const line_no = readShort(code_ptr, &ip);
                const col = readShort(code_ptr, &ip);
                vm.current_line = line_no;
                vm.current_column = if (col == 0) 1 else col;
                if (vm.frame_count > 0) {
                    cur_frame.line = vm.current_line;
                    cur_frame.column = vm.current_column;
                }
            },
            .OP_SOURCE => {
                const idx = readShort(code_ptr, &ip);
                debug_ops.source(vm, idx);
                if (vm.frame_count > 0) {
                    cur_frame = &vm.frames[vm.frame_count - 1];
                }
            },
            .OP_CONSTANT => {
                const c_idx = readShort(code_ptr, &ip);
                if (ip + 2 <= code_len and
                    code_ptr[ip] == @intFromEnum(OpCode.OP_MUL_TYPED) and
                    (code_ptr[ip + 1] == @intFromEnum(widths.Width.i64) or code_ptr[ip + 1] == @intFromEnum(widths.Width.isize)) and
                    sp > 0 and stack_buf[sp - 1] == .i64 and constants[c_idx] == .i64)
                {
                    stack_buf[sp - 1].i64 *%= constants[c_idx].i64;
                    ip += 2;
                    continue;
                }
                if (ip < code_len and code_ptr[ip] == @intFromEnum(OpCode.OP_DIV) and
                    sp > 0 and stack_buf[sp - 1] == .i64 and constants[c_idx] == .i64 and constants[c_idx].i64 != 0)
                {
                    stack_buf[sp - 1].i64 = @divTrunc(stack_buf[sp - 1].i64, constants[c_idx].i64);
                    ip += 1;
                    continue;
                }
                if (sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = constants[c_idx];
                    sp += 1;
                } else return error.OutOfMemory;
            },
            .OP_NULL => {
                if (sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = .null;
                    sp += 1;
                } else return error.OutOfMemory;
            },
            .OP_TRUE => {
                if (sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = .{ .u1 = 1 };
                    sp += 1;
                } else return error.OutOfMemory;
            },
            .OP_FALSE => {
                if (sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = .{ .u1 = 0 };
                    sp += 1;
                } else return error.OutOfMemory;
            },
            .OP_POP => {
                sp -= 1;
            },
            .OP_DUP => {
                if (sp < state_mod.STACK_MAX and sp > 0) {
                    stack_buf[sp] = stack_buf[sp - 1];
                    sp += 1;
                } else return error.OutOfMemory;
            },
            .OP_PRINT => {
                syncVM(vm, sp);
                print_builtin.printArgs(vm, readByte(code_ptr, &ip)) catch return error.RuntimeError;
                sp = vm.sp;
            },
            .OP_ADD => {
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64) {
                    stack_buf[sp - 2].i64 +%= stack_buf[sp - 1].i64;
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArith(vm, .OP_ADD);
                    sp = vm.sp;
                }
            },
            .OP_SUB => {
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64) {
                    stack_buf[sp - 2].i64 -%= stack_buf[sp - 1].i64;
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArith(vm, .OP_SUB);
                    sp = vm.sp;
                }
            },
            .OP_MUL => {
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64) {
                    stack_buf[sp - 2].i64 *%= stack_buf[sp - 1].i64;
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArith(vm, .OP_MUL);
                    sp = vm.sp;
                }
            },
            .OP_DIV => {
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64 and stack_buf[sp - 1].i64 != 0) {
                    stack_buf[sp - 2].i64 = @divTrunc(stack_buf[sp - 2].i64, stack_buf[sp - 1].i64);
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArith(vm, .OP_DIV);
                    sp = vm.sp;
                }
            },
            .OP_MOD => {
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64 and stack_buf[sp - 1].i64 != 0) {
                    stack_buf[sp - 2].i64 = @rem(stack_buf[sp - 2].i64, stack_buf[sp - 1].i64);
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArith(vm, .OP_MOD);
                    sp = vm.sp;
                }
            },
            .OP_POW => {
                syncVM(vm, sp);
                try arith.binArith(vm, .OP_POW);
                sp = vm.sp;
            },
            .OP_BIT_AND, .OP_BIT_OR, .OP_BIT_XOR, .OP_SHL, .OP_SHR => {
                syncVM(vm, sp);
                try arith.binBitwise(vm, op);
                sp = vm.sp;
            },
            .OP_NEGATE => {
                syncVM(vm, sp);
                try arith.negate(vm);
                sp = vm.sp;
            },
            .OP_NOT => {
                syncVM(vm, sp);
                try arith.not_(vm);
                sp = vm.sp;
            },
            .OP_BIT_NOT => {
                syncVM(vm, sp);
                try arith.bitNot(vm);
                sp = vm.sp;
            },
            .OP_EQUAL => {
                syncVM(vm, sp);
                try compare.compareEq(vm, false);
                sp = vm.sp;
            },
            .OP_NOT_EQUAL => {
                syncVM(vm, sp);
                try compare.compareEq(vm, true);
                sp = vm.sp;
            },
            .OP_LESS, .OP_LESS_EQUAL, .OP_GREATER, .OP_GREATER_EQUAL => {
                syncVM(vm, sp);
                try compare.compareOrd(vm, op);
                sp = vm.sp;
            },
            .OP_JUMP => {
                const off = readShort(code_ptr, &ip);
                ip += off;
            },
            .OP_JUMP_IF_FALSE => {
                const off = readShort(code_ptr, &ip);
                if (!stack_buf[sp - 1].isTruthy()) ip += off;
            },
            .OP_JUMP_IF_NULL => {
                const off = readShort(code_ptr, &ip);
                if (stack_buf[sp - 1] == .null) ip += off;
            },
            .OP_LOOP => {
                const off = readShort(code_ptr, &ip);
                ip -= off;
            },
            .OP_FOR_PREP => {
                const i_slot = readByte(code_ptr, &ip);
                const end_slot = readByte(code_ptr, &ip);
                const skip = readShort(code_ptr, &ip);
                const i_idx = base_slot + i_slot;
                const end_idx = base_slot + end_slot;
                if (i_idx < sp and end_idx < sp) {
                    const i_val = stack_buf[i_idx];
                    const end_val = stack_buf[end_idx];
                    if (i_val == .i64 and end_val == .i64) {
                        if (i_val.i64 >= end_val.i64) ip += skip;
                        continue;
                    }
                }
                syncVM(vm, sp);
                control.forPrep(vm, &ip, i_slot, end_slot, skip) catch return error.TypeError;
                sp = vm.sp;
            },
            .OP_FOR_LOOP => {
                const i_slot = readByte(code_ptr, &ip);
                const end_slot = readByte(code_ptr, &ip);
                const back = readShort(code_ptr, &ip);
                const i_idx = base_slot + i_slot;
                const end_idx = base_slot + end_slot;
                if (i_idx < sp and end_idx < sp) {
                    const i_val = &stack_buf[i_idx];
                    const end_val = stack_buf[end_idx];
                    if (i_val.* == .i64 and end_val == .i64) {
                        const next = i_val.i64 +% 1;
                        i_val.i64 = next;
                        if (next < end_val.i64) {
                            const target = ip - back;
                            if (target < code_len) {
                                const target_op = code_ptr[target];
                                if (target_op == @intFromEnum(OpCode.OP_GET_GLOBAL) and target + 3 <= code_len) {
                                    const g_slot = std.mem.readInt(u16, code_ptr[target + 1 ..][0..2], .big);
                                    if (g_slot < global_count and sp < state_mod.STACK_MAX) {
                                        stack_buf[sp] = globals[g_slot];
                                        sp += 1;
                                        ip = target + 3;
                                        continue;
                                    }
                                } else if (target_op == @intFromEnum(OpCode.OP_GET_LOCAL) and target + 2 <= code_len) {
                                    const l_slot = code_ptr[target + 1];
                                    const l_idx = base_slot + l_slot;
                                    if (l_idx < sp and sp < state_mod.STACK_MAX) {
                                        stack_buf[sp] = stack_buf[l_idx];
                                        sp += 1;
                                        ip = target + 2;
                                        continue;
                                    }
                                }
                            }
                            ip = target;
                        }
                        continue;
                    }
                }
                syncVM(vm, sp);
                control.forLoop(vm, &ip, i_slot, end_slot, back) catch return error.TypeError;
                sp = vm.sp;
            },
            .OP_ADD_TYPED => {
                const width_byte = readByte(code_ptr, &ip);
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64 and
                    (width_byte == @intFromEnum(widths.Width.i64) or width_byte == @intFromEnum(widths.Width.isize)))
                {
                    stack_buf[sp - 2].i64 +%= stack_buf[sp - 1].i64;
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArithTyped(vm, .add, width_byte);
                    sp = vm.sp;
                }
            },
            .OP_SUB_TYPED => {
                const width_byte = readByte(code_ptr, &ip);
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64 and
                    (width_byte == @intFromEnum(widths.Width.i64) or width_byte == @intFromEnum(widths.Width.isize)))
                {
                    stack_buf[sp - 2].i64 -%= stack_buf[sp - 1].i64;
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArithTyped(vm, .sub, width_byte);
                    sp = vm.sp;
                }
            },
            .OP_MUL_TYPED => {
                const width_byte = readByte(code_ptr, &ip);
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64 and
                    (width_byte == @intFromEnum(widths.Width.i64) or width_byte == @intFromEnum(widths.Width.isize)))
                {
                    stack_buf[sp - 2].i64 *%= stack_buf[sp - 1].i64;
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.binArithTyped(vm, .mul, width_byte);
                    sp = vm.sp;
                }
            },
            .OP_LT_TYPED => {
                const width_byte = readByte(code_ptr, &ip);
                if (sp >= 2 and stack_buf[sp - 2] == .i64 and stack_buf[sp - 1] == .i64) {
                    // Read payloads before writing: the result location overlaps
                    // the operands, and writing the `.u1` tag first would make
                    // a subsequent `.i64` field access a safety panic.
                    const l = stack_buf[sp - 2].i64;
                    const r = stack_buf[sp - 1].i64;
                    stack_buf[sp - 2] = .{ .u1 = if (l < r) 1 else 0 };
                    sp -= 1;
                } else {
                    syncVM(vm, sp);
                    try arith.ltTyped(vm, width_byte);
                    sp = vm.sp;
                }
            },
            .OP_RETURN => {
                syncVM(vm, sp);
                if (try call.doReturn(vm, &ip)) return;
                sp = vm.sp;
                cur_frame = &vm.frames[vm.frame_count - 1];
                base_slot = cur_frame.base_slot;
            },
            .OP_GET_LOCAL => {
                const slot = readByte(code_ptr, &ip);
                const idx = base_slot + slot;
                if (ip + 2 <= code_len and
                    code_ptr[ip] == @intFromEnum(OpCode.OP_ADD_TYPED) and
                    (code_ptr[ip + 1] == @intFromEnum(widths.Width.i64) or code_ptr[ip + 1] == @intFromEnum(widths.Width.isize)) and
                    sp > 0 and idx < sp and stack_buf[sp - 1] == .i64 and stack_buf[idx] == .i64)
                {
                    stack_buf[sp - 1].i64 +%= stack_buf[idx].i64;
                    ip += 2;
                    if (ip + 4 <= code_len and
                        code_ptr[ip] == @intFromEnum(OpCode.OP_SET_GLOBAL) and
                        code_ptr[ip + 3] == @intFromEnum(OpCode.OP_POP))
                    {
                        const set_slot = std.mem.readInt(u16, code_ptr[ip + 1 ..][0..2], .big);
                        if (set_slot < global_count) {
                            globals[set_slot] = stack_buf[sp - 1];
                            sp -= 1;
                            ip += 4;
                            if (ip + 5 <= code_len and code_ptr[ip] == @intFromEnum(OpCode.OP_FOR_LOOP)) {
                                const fi_slot = code_ptr[ip + 1];
                                const fe_slot = code_ptr[ip + 2];
                                const fback = std.mem.readInt(u16, code_ptr[ip + 3 ..][0..2], .big);
                                const fi_idx = base_slot + fi_slot;
                                const fe_idx = base_slot + fe_slot;
                                if (fi_idx < sp and fe_idx < sp and stack_buf[fi_idx] == .i64 and stack_buf[fe_idx] == .i64) {
                                    const next = stack_buf[fi_idx].i64 +% 1;
                                    stack_buf[fi_idx].i64 = next;
                                    if (next < stack_buf[fe_idx].i64) {
                                        ip = (ip + 5) - fback;
                                        if (ip + 3 <= code_len and
                                            code_ptr[ip] == @intFromEnum(OpCode.OP_GET_GLOBAL) and
                                            std.mem.readInt(u16, code_ptr[ip + 1 ..][0..2], .big) == set_slot and
                                            sp < state_mod.STACK_MAX)
                                        {
                                            stack_buf[sp] = globals[set_slot];
                                            sp += 1;
                                            ip += 3;
                                        }
                                        continue;
                                    }
                                    ip += 5;
                                    continue;
                                }
                            }
                        }
                    }
                    continue;
                }
                if (ip + 2 <= code_len and
                    code_ptr[ip] == @intFromEnum(OpCode.OP_SUB_TYPED) and
                    (code_ptr[ip + 1] == @intFromEnum(widths.Width.i64) or code_ptr[ip + 1] == @intFromEnum(widths.Width.isize)) and
                    sp > 0 and idx < sp and stack_buf[sp - 1] == .i64 and stack_buf[idx] == .i64)
                {
                    stack_buf[sp - 1].i64 -%= stack_buf[idx].i64;
                    ip += 2;
                    continue;
                }
                if (idx < sp and sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = stack_buf[idx];
                    sp += 1;
                } else {
                    syncVM(vm, sp);
                    try vars.getLocal(vm, slot);
                    sp = vm.sp;
                }
            },
            .OP_SET_LOCAL => {
                const slot = readByte(code_ptr, &ip);
                if (cur_frame.isConst(slot)) return runtime.runtimeFail(vm, "Cannot assign to @const binding");
                const idx = base_slot + slot;
                if (ip < code_len and code_ptr[ip] == @intFromEnum(OpCode.OP_POP)) {
                    ip += 1;
                    if (idx < sp and sp > 0) {
                        sp -= 1;
                        stack_buf[idx] = stack_buf[sp];
                        if (ip + 2 <= code_len and
                            code_ptr[ip] == @intFromEnum(OpCode.OP_GET_LOCAL) and
                            code_ptr[ip + 1] == slot)
                        {
                            ip += 2;
                            sp += 1;
                        }
                        continue;
                    }
                    syncVM(vm, sp);
                    try vars.setLocal(vm, slot);
                    _ = stack.pop(vm);
                    sp = vm.sp;
                } else {
                    if (idx < sp and sp > 0) {
                        stack_buf[idx] = stack_buf[sp - 1];
                    } else {
                        syncVM(vm, sp);
                        try vars.setLocal(vm, slot);
                        sp = vm.sp;
                    }
                }
            },
            .OP_GET_GLOBAL => {
                const slot = readShort(code_ptr, &ip);
                if (slot < global_count and sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = globals[slot];
                    sp += 1;
                } else {
                    syncVM(vm, sp);
                    try vars.getGlobal(vm, slot);
                    sp = vm.sp;
                }
            },
            .OP_SET_GLOBAL => {
                const slot = readShort(code_ptr, &ip);
                if (ip < code_len and code_ptr[ip] == @intFromEnum(OpCode.OP_POP)) {
                    ip += 1;
                    if (slot < global_count and sp > 0) {
                        sp -= 1;
                        globals[slot] = stack_buf[sp];
                        if (ip + 3 <= code_len and
                            code_ptr[ip] == @intFromEnum(OpCode.OP_GET_GLOBAL) and
                            std.mem.readInt(u16, code_ptr[ip + 1 ..][0..2], .big) == slot)
                        {
                            ip += 3;
                            sp += 1;
                        }
                        continue;
                    }
                    syncVM(vm, sp);
                    try vars.setGlobal(vm, slot);
                    _ = stack.pop(vm);
                    sp = vm.sp;
                } else {
                    if (slot < global_count and sp > 0) {
                        globals[slot] = stack_buf[sp - 1];
                    } else {
                        syncVM(vm, sp);
                        try vars.setGlobal(vm, slot);
                        sp = vm.sp;
                    }
                }
            },
            .OP_GET_FUNCTION => {
                syncVM(vm, sp);
                try vars.getFunction(vm, readShort(code_ptr, &ip));
                sp = vm.sp;
            },
            .OP_CALL => {
                const argc = readByte(code_ptr, &ip);
                syncVM(vm, sp);
                try call.callDynamic(vm, &ip, argc);
                sp = vm.sp;
                cur_frame = &vm.frames[vm.frame_count - 1];
                base_slot = cur_frame.base_slot;
            },
            .OP_CALL_STATIC => {
                const addr = readShort(code_ptr, &ip);
                const argc = readByte(code_ptr, &ip);
                syncVM(vm, sp);
                try call.callStatic(vm, &ip, addr, argc);
                sp = vm.sp;
                cur_frame = &vm.frames[vm.frame_count - 1];
                base_slot = cur_frame.base_slot;
            },
            .OP_PACK_REST => {
                syncVM(vm, sp);
                try call.packRest(vm, readByte(code_ptr, &ip));
                sp = vm.sp;
            },
            .OP_MAKE_STRING => {
                syncVM(vm, sp);
                try heap.makeString(vm);
                sp = vm.sp;
            },
            .OP_MAKE_ERROR => {
                syncVM(vm, sp);
                try heap.makeError(vm);
                sp = vm.sp;
            },
            .OP_MAKE_ERROR_PAYLOAD => {
                syncVM(vm, sp);
                try heap.makeErrorPayload(vm);
                sp = vm.sp;
            },
            .OP_IS_ERROR => {
                syncVM(vm, sp);
                try heap.isError(vm);
                sp = vm.sp;
            },
            .OP_ERROR_NAME => {
                syncVM(vm, sp);
                try heap.errorName(vm);
                sp = vm.sp;
            },
            .OP_STRING_ADD => {
                syncVM(vm, sp);
                try heap.stringAdd(vm);
                sp = vm.sp;
            },
            .OP_GET_INDEX => {
                syncVM(vm, sp);
                try heap.getIndex(vm);
                sp = vm.sp;
            },
            .OP_SET_INDEX => {
                syncVM(vm, sp);
                try heap.setIndex(vm);
                sp = vm.sp;
            },
            .OP_LOAD_FIELD => {
                const off = readShort(code_ptr, &ip);
                const kind = readByte(code_ptr, &ip);
                syncVM(vm, sp);
                try heap.loadField(vm, off, kind);
                sp = vm.sp;
            },
            .OP_STORE_FIELD => {
                const off = readShort(code_ptr, &ip);
                const kind = readByte(code_ptr, &ip);
                syncVM(vm, sp);
                try heap.storeField(vm, off, kind);
                sp = vm.sp;
            },
            .OP_GET_ARRAY => {
                syncVM(vm, sp);
                try heap.getArray(vm);
                sp = vm.sp;
            },
            .OP_SET_ARRAY => {
                syncVM(vm, sp);
                try heap.setArray(vm);
                sp = vm.sp;
            },
            .OP_SLICE => {
                syncVM(vm, sp);
                try heap.sliceView(vm);
                sp = vm.sp;
            },
            .OP_MARK_CONST => {
                cur_frame.markConst(readByte(code_ptr, &ip));
            },
            .OP_ASSERT_TYPE => {
                _ = readByte(code_ptr, &ip);
            },
            .OP_SIZEOF => {
                sp -= 1;
                const val = stack_buf[sp];
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
                stack_buf[sp] = .{ .i64 = size };
                sp += 1;
            },
            .OP_AS => {
                const kind = readByte(code_ptr, &ip);
                const w: widths.Width = @enumFromInt(kind);
                const top = stack_buf[sp - 1];
                if (top == .i64 and (w == .i64 or w == .isize)) {
                    // Fast path: already i64 on stack top, no-op
                } else if (top == .f64 and (w == .f64 or w == .fsize)) {
                    // Fast path: already f64 on stack top, no-op
                } else {
                    syncVM(vm, sp);
                    const val = stack.pop(vm);
                    const out = widths.castValue(val, w) catch |err| switch (err) {
                        error.OutOfRange => return runtime.runtimeFail(vm, "@as: value out of range for target width"),
                        else => return error.RuntimeError,
                    };
                    try stack.push(vm, out);
                    sp = vm.sp;
                }
            },
            .OP_STRING_EQUAL, .OP_STRING_NOT_EQUAL => {
                syncVM(vm, sp);
                try compare.compareEq(vm, op == .OP_STRING_NOT_EQUAL);
                sp = vm.sp;
            },
            .OP_IMPORT => {
                _ = readShort(code_ptr, &ip);
            },
            .OP_GET_PROPERTY => {
                syncVM(vm, sp);
                try getProperty(vm, readShort(code_ptr, &ip));
                sp = vm.sp;
            },
            .OP_SET_PROPERTY => {
                syncVM(vm, sp);
                try setProperty(vm, readShort(code_ptr, &ip));
                sp = vm.sp;
            },
            .OP_GET_MODULE => {
                const name_val = vm.chunk.constants.items[readShort(code_ptr, &ip)];
                const module_name = switch (name_val) {
                    .name => |i| vm.chunk.stringAt(i),
                    else => return error.RuntimeError,
                };
                const mod = try vm.allocModule(module_name);
                if (sp < state_mod.STACK_MAX) {
                    stack_buf[sp] = .{ .module = mod };
                    sp += 1;
                } else return error.OutOfMemory;
            },
        }
    }
    syncVM(vm, sp);
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
