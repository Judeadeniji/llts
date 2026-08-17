//! LLVM IR codegen for expressions.

const std = @import("std");
const llvm = @import("llvm");
const T = llvm.types;
const C = llvm.core;
const ast = @import("../../ast/root.zig");
const context = @import("context.zig");
const types_mod = @import("types.zig");
const layout = @import("../layout.zig");
const from_ast = @import("../typecheck/from_ast.zig");
const target = llvm.target;
const LlvmContext = context.LlvmContext;

pub const CodegenError = error{
    UnsupportedExpression,
    UnsupportedOperator,
    UndefinedVariable,
    InvalidLiteral,
    OutOfMemory,
};

pub const ExprState = struct {
    lc: *LlvmContext,
    /// Local name → alloca'd stack slot.
    locals: *std.StringHashMap(T.LLVMValueRef),
};

/// Look up the typechecker's per-node type. Fall back to i64 only when unknown/missing.
pub fn typeOf(s: *ExprState, node: *ast.Node) []const u8 {
    if (s.lc.state.type_of_results.get(node)) |t| {
        if (!std.mem.eql(u8, layout.unwrapTypeName(t), "unknown")) return t;
    }
    return "i64";
}

fn llvmTypeOf(s: *ExprState, node: *ast.Node) T.LLVMTypeRef {
    return types_mod.resolveOrSlot(s.lc, typeOf(s, node));
}

/// Lower an AST expression node to an LLVM value (SSA).
pub fn lowerExpr(s: *ExprState, node: *ast.Node) CodegenError!T.LLVMValueRef {
    return switch (node.*) {
        .literal => |lit| lowerLiteral(s, lit, typeOf(s, node)),
        .primary => |prim| lowerPrimary(s, prim, node),
        .binary => |bin| lowerBinary(s, bin, node),
        .unary => |un| lowerUnary(s, un, node),
        .call => |call| lowerCall(s, call, node),
        .member => |mem| lowerMember(s, mem, node),
        .index => |idx| lowerIndex(s, idx, node),
        .assignment => |asg| lowerAssignment(s, asg),
        .struct_init => |si| lowerStructInit(s, si, node),
        .array_literal => |al| lowerArrayLiteral(s, al, node),
        .try_expr => |te| lowerTry(s, te, node),
        .error_expr => |ee| lowerError(s, ee),
        else => poison(s, node),
    };
}

fn poison(s: *ExprState, node: *ast.Node) CodegenError!T.LLVMValueRef {
    return C.LLVMGetUndef(llvmTypeOf(s, node));
}

fn lowerLiteral(s: *ExprState, lit: ast.Literal, type_name: []const u8) CodegenError!T.LLVMValueRef {
    const ty = types_mod.resolveOrSlot(s.lc, type_name);
    return switch (lit.literal_type) {
        .number => {
            if (types_mod.isFloatName(type_name)) {
                const v = std.fmt.parseFloat(f64, lit.value) catch return error.InvalidLiteral;
                return C.LLVMConstReal(ty, v);
            }
            if (std.fmt.parseInt(i64, lit.value, 10)) |v| {
                return C.LLVMConstInt(ty, @bitCast(v), 1);
            } else |_| {}
            if (std.fmt.parseFloat(f64, lit.value)) |v| {
                return C.LLVMConstReal(s.lc.f64Ty(), v);
            } else |_| {}
            return error.InvalidLiteral;
        },
        .hex => {
            const raw = if (std.mem.startsWith(u8, lit.value, "0x") or std.mem.startsWith(u8, lit.value, "0X")) lit.value[2..] else lit.value;
            const v = std.fmt.parseInt(u64, raw, 16) catch return error.InvalidLiteral;
            return C.LLVMConstInt(ty, v, 0);
        },
        .octal => {
            const raw = if (std.mem.startsWith(u8, lit.value, "0o") or std.mem.startsWith(u8, lit.value, "0O")) lit.value[2..] else lit.value;
            const v = std.fmt.parseInt(u64, raw, 8) catch return error.InvalidLiteral;
            return C.LLVMConstInt(ty, v, 0);
        },
        .binary => {
            const raw = if (std.mem.startsWith(u8, lit.value, "0b") or std.mem.startsWith(u8, lit.value, "0B")) lit.value[2..] else lit.value;
            const v = std.fmt.parseInt(u64, raw, 2) catch return error.InvalidLiteral;
            return C.LLVMConstInt(ty, v, 0);
        },
        .boolean => {
            const v: u64 = if (std.mem.eql(u8, lit.value, "true")) 1 else 0;
            return C.LLVMConstInt(ty, v, 0);
        },
        .@"null" => C.LLVMConstNull(ty),
        .string => lowerStringLiteral(s, lit.value),
    };
}

fn lowerStringLiteral(s: *ExprState, text: []const u8) CodegenError!T.LLVMValueRef {
    const name_z = s.lc.allocator.dupeZ(u8, text) catch return error.OutOfMemory;
    defer s.lc.allocator.free(name_z);
    return C.LLVMBuildGlobalStringPtr(s.lc.builder, name_z, ".str");
}

fn lowerPrimary(s: *ExprState, prim: ast.Primary, node: *ast.Node) CodegenError!T.LLVMValueRef {
    if (prim.kind == .identifier or prim.kind == .register) {
        if (s.locals.get(prim.name)) |slot| {
            const ty = llvmTypeOf(s, node);
            const name_z = s.lc.allocator.dupeZ(u8, prim.name) catch return error.OutOfMemory;
            defer s.lc.allocator.free(name_z);
            return C.LLVMBuildLoad2(s.lc.builder, ty, slot, name_z);
        }
        if (s.lc.globals.get(prim.name)) |slot| {
            const ty = llvmTypeOf(s, node);
            const name_z = s.lc.allocator.dupeZ(u8, prim.name) catch return error.OutOfMemory;
            defer s.lc.allocator.free(name_z);
            return C.LLVMBuildLoad2(s.lc.builder, ty, slot, name_z);
        }
        if (s.lc.functions.get(prim.name)) |fn_val| {
            return fn_val;
        }
        return C.LLVMGetUndef(llvmTypeOf(s, node));
    }
    return C.LLVMGetUndef(llvmTypeOf(s, node));
}

fn ensurePrintf(s: *ExprState) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get("printf")) |f| return f;
    const i8ptr = s.lc.ptrTy();
    var params = [_]T.LLVMTypeRef{i8ptr};
    const fn_ty = C.LLVMFunctionType(s.lc.i32Ty(), &params, 1, 1);
    const f = C.LLVMAddFunction(s.lc.mod, "printf", fn_ty);
    try s.lc.functions.put("printf", f);
    return f;
}

fn ensureMalloc(s: *ExprState) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get("malloc")) |f| return f;
    var params = [_]T.LLVMTypeRef{s.lc.i64Ty()};
    const fn_ty = C.LLVMFunctionType(s.lc.ptrTy(), &params, 1, 0);
    const f = C.LLVMAddFunction(s.lc.mod, "malloc", fn_ty);
    try s.lc.functions.put("malloc", f);
    return f;
}

fn lowerPrint(s: *ExprState, call: ast.Call) CodegenError!T.LLVMValueRef {
    const printf = try ensurePrintf(s);
    const printf_ty = C.LLVMGlobalGetValueType(printf);
    for (call.args) |arg| {
        const val = try lowerExpr(s, arg);
        const tname = typeOf(s, arg);
        if (types_mod.isFloatName(tname)) {
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%g ", "fmt");
            var args = [_]T.LLVMValueRef{ fmt, types_mod.castTo(s.lc, val, s.lc.f64Ty()) };
            _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &args, 2, "");
        } else if (std.mem.eql(u8, layout.unwrapTypeName(tname), "string") or
            std.mem.eql(u8, layout.unwrapTypeName(tname), "[]byte") or
            std.mem.eql(u8, layout.unwrapTypeName(tname), "[]u8"))
        {
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%s ", "fmt");
            var args = [_]T.LLVMValueRef{ fmt, val };
            _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &args, 2, "");
        } else {
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%lld ", "fmt");
            const as_i64 = types_mod.castTo(s.lc, val, s.lc.i64Ty());
            var args = [_]T.LLVMValueRef{ fmt, as_i64 };
            _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &args, 2, "");
        }
    }
    const nl = C.LLVMBuildGlobalStringPtr(s.lc.builder, "\n", "nl");
    var nl_args = [_]T.LLVMValueRef{nl};
    _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &nl_args, 1, "");
    return C.LLVMConstNull(s.lc.i64Ty());
}

fn lowerIntrinsic(s: *ExprState, name: []const u8, call: ast.Call, node: *ast.Node) CodegenError!T.LLVMValueRef {
    if (std.mem.eql(u8, name, "@as")) {
        if (call.args.len < 2) return poison(s, node);
        const val = try lowerExpr(s, call.args[1]);
        return types_mod.castTo(s.lc, val, llvmTypeOf(s, node));
    }
    if (std.mem.eql(u8, name, "@sizeOf")) {
        if (call.args.len >= 1) {
            if (from_ast.typeAstToDisplay(call.args[0], s.lc.state)) |disp_opt| {
                if (disp_opt) |disp| {
                    const lty = types_mod.resolveOrSlot(s.lc, disp);
                    const dl = target.LLVMGetModuleDataLayout(s.lc.mod);
                    const sz = target.LLVMABISizeOfType(dl, lty);
                    return C.LLVMConstInt(s.lc.i64Ty(), sz, 0);
                }
            } else |_| {}
        }
        return C.LLVMConstInt(s.lc.i64Ty(), 8, 0);
    }
    if (std.mem.eql(u8, name, "@typeOf")) {
        return poison(s, node);
    }
    if (std.mem.eql(u8, name, "@isError")) {
        const val = try lowerExpr(s, call.args[0]);
        // Error tag convention: high bit of i64 set, or null check — treat non-zero as error for now.
        const zero = C.LLVMConstInt(C.LLVMTypeOf(val), 0, 0);
        return C.LLVMBuildICmp(s.lc.builder, .LLVMIntNE, val, zero, "iserr");
    }
    if (std.mem.eql(u8, name, "@new")) {
        // @new(allocator, value) — ignore allocator; malloc + store value.
        if (call.args.len < 2) return poison(s, node);
        const val = try lowerExpr(s, call.args[1]);
        const val_ty = C.LLVMTypeOf(val);
        const dl = target.LLVMGetModuleDataLayout(s.lc.mod);
        const sz = target.LLVMABISizeOfType(dl, val_ty);
        const malloc = try ensureMalloc(s);
        const malloc_ty = C.LLVMGlobalGetValueType(malloc);
        var args = [_]T.LLVMValueRef{C.LLVMConstInt(s.lc.i64Ty(), sz, 0)};
        const ptr = C.LLVMBuildCall2(s.lc.builder, malloc_ty, malloc, &args, 1, "new");
        _ = C.LLVMBuildStore(s.lc.builder, val, ptr);
        return ptr;
    }
    if (std.mem.eql(u8, name, "@import")) {
        return poison(s, node);
    }
    for (call.args) |arg| _ = try lowerExpr(s, arg);
    return poison(s, node);
}

fn lowerCall(s: *ExprState, call: ast.Call, node: *ast.Node) CodegenError!T.LLVMValueRef {
    // Method call: obj.method(args) → Struct::method(obj, args…)
    if (call.callee.* == .member) {
        if (try lowerMethodCall(s, call, node)) |v| return v;
    }

    const fn_name = resolveCalleeName(call.callee) orelse {
        _ = try lowerExpr(s, call.callee);
        for (call.args) |arg| _ = try lowerExpr(s, arg);
        return poison(s, node);
    };

    if (std.mem.eql(u8, fn_name, "print") or std.mem.eql(u8, fn_name, "__printLn")) {
        return try lowerPrint(s, call);
    }

    if (std.mem.startsWith(u8, fn_name, "@")) {
        return try lowerIntrinsic(s, fn_name, call, node);
    }

    // std.debug.printLn → printf-style
    if (std.mem.endsWith(u8, fn_name, "printLn") or std.mem.eql(u8, fn_name, "printLn")) {
        return try lowerPrint(s, call);
    }

    const fn_val = s.lc.functions.get(fn_name) orelse blk: {
        // External or not-yet-declared: declare variadic i64 stub returning node type.
        const fn_name_z = s.lc.allocator.dupeZ(u8, fn_name) catch return error.OutOfMemory;
        defer s.lc.allocator.free(fn_name_z);
        const ret = llvmTypeOf(s, node);
        const fn_ty = C.LLVMFunctionType(ret, null, 0, 1);
        const decl = C.LLVMAddFunction(s.lc.mod, fn_name_z, fn_ty);
        try s.lc.functions.put(fn_name, decl);
        break :blk decl;
    };

    const argv = s.lc.allocator.alloc(T.LLVMValueRef, call.args.len) catch return error.OutOfMemory;
    defer s.lc.allocator.free(argv);
    const fn_ty = C.LLVMGlobalGetValueType(fn_val);
    const param_count: usize = @intCast(C.LLVMCountParamTypes(fn_ty));
    var param_tys: []T.LLVMTypeRef = &.{};
    if (param_count > 0) {
        param_tys = s.lc.allocator.alloc(T.LLVMTypeRef, param_count) catch return error.OutOfMemory;
        C.LLVMGetParamTypes(fn_ty, param_tys.ptr);
    }
    defer if (param_count > 0) s.lc.allocator.free(param_tys);
    for (call.args, 0..) |arg, i| {
        var v = try lowerExpr(s, arg);
        if (i < param_count) v = types_mod.castTo(s.lc, v, param_tys[i]);
        argv[i] = v;
    }

    const ret_ty = C.LLVMGetReturnType(fn_ty);
    const name_z: [*:0]const u8 = if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) "" else "call";
    return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, argv.ptr, @intCast(argv.len), name_z);
}

fn lowerMethodCall(s: *ExprState, call: ast.Call, node: *ast.Node) CodegenError!?T.LLVMValueRef {
    const mem = call.callee.member;
    if (mem.property.* != .primary) return null;
    const method_name = mem.property.primary.name;
    const obj_type_name = layout.unwrapTypeName(typeOf(s, mem.object));

    var mangled_buf: [256]u8 = undefined;
    const mangled = std.fmt.bufPrint(&mangled_buf, "{s}::{s}", .{ obj_type_name, method_name }) catch return null;

    const fn_val = s.lc.functions.get(mangled) orelse return null;
    const obj_val = try lowerExpr(s, mem.object);

    const argv = s.lc.allocator.alloc(T.LLVMValueRef, call.args.len + 1) catch return error.OutOfMemory;
    defer s.lc.allocator.free(argv);
    argv[0] = obj_val;
    for (call.args, 0..) |arg, i| argv[i + 1] = try lowerExpr(s, arg);

    const fn_ty = C.LLVMGlobalGetValueType(fn_val);
    const param_count = C.LLVMCountParamTypes(fn_ty);
    if (param_count > 0) {
        const param_tys = s.lc.allocator.alloc(T.LLVMTypeRef, param_count) catch return error.OutOfMemory;
        defer s.lc.allocator.free(param_tys);
        C.LLVMGetParamTypes(fn_ty, param_tys.ptr);
        for (argv, 0..) |*a, i| {
            if (i < param_count) a.* = types_mod.castTo(s.lc, a.*, param_tys[i]);
        }
    }
    const ret_ty = C.LLVMGetReturnType(fn_ty);
    const name_z: [*:0]const u8 = if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) "" else "mcall";
    const res = C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, argv.ptr, @intCast(argv.len), name_z);
    _ = node;
    return res;
}

fn resolveCalleeName(node: *ast.Node) ?[]const u8 {
    return switch (node.*) {
        .primary => |p| if (p.kind == .identifier) p.name else null,
        .member => |m| resolveCalleeName(m.property),
        else => null,
    };
}

fn lowerMember(s: *ExprState, mem_node: ast.Member, node: *ast.Node) CodegenError!T.LLVMValueRef {
    // Enum.Variant → i64 tag
    if (mem_node.object.* == .primary and mem_node.property.* == .primary) {
        const obj_name = mem_node.object.primary.name;
        if (s.lc.state.enums.get(obj_name)) |ed| {
            if (ed.variants.get(mem_node.property.primary.name)) |tag| {
                return C.LLVMConstInt(s.lc.i64Ty(), @intCast(tag), 0);
            }
        }
    }

    const obj_val = try lowerExpr(s, mem_node.object);
    const obj_type_name = layout.unwrapTypeName(typeOf(s, mem_node.object));

    if (mem_node.property.* == .primary and mem_node.property.primary.kind == .identifier) {
        const field_name = mem_node.property.primary.name;
        if (types_mod.getStructFieldIndex(s.lc, obj_type_name, field_name)) |idx| {
            const obj_ty = types_mod.resolveOrSlot(s.lc, obj_type_name);
            // Pointer receiver: GEP directly
            if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj_val)) == .LLVMPointerTypeKind) {
                const field_ptr = C.LLVMBuildStructGEP2(s.lc.builder, obj_ty, obj_val, idx, "field_ptr");
                return C.LLVMBuildLoad2(s.lc.builder, llvmTypeOf(s, node), field_ptr, "field_val");
            }
            const temp_ptr = C.LLVMBuildAlloca(s.lc.builder, obj_ty, "tmp_struct");
            _ = C.LLVMBuildStore(s.lc.builder, obj_val, temp_ptr);
            const field_ptr = C.LLVMBuildStructGEP2(s.lc.builder, obj_ty, temp_ptr, idx, "field_ptr");
            return C.LLVMBuildLoad2(s.lc.builder, llvmTypeOf(s, node), field_ptr, "field_val");
        }
    }
    return C.LLVMGetUndef(llvmTypeOf(s, node));
}

fn lowerIndex(s: *ExprState, idx: ast.Index, node: *ast.Node) CodegenError!T.LLVMValueRef {
    const obj = try lowerExpr(s, idx.object);
    if (idx.is_slice) {
        // Slice view → pointer into array (start offset).
        const start = if (idx.index) |i| try lowerExpr(s, i) else C.LLVMConstInt(s.lc.i64Ty(), 0, 0);
        _ = start;
        if (idx.end) |e| _ = try lowerExpr(s, e);
        return types_mod.castTo(s.lc, obj, llvmTypeOf(s, node));
    }
    const index_val = if (idx.index) |i| try lowerExpr(s, i) else return poison(s, node);
    const obj_ty_name = typeOf(s, idx.object);
    const elem_ty = llvmTypeOf(s, node);

    if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMPointerTypeKind) {
        var indices = [_]T.LLVMValueRef{index_val};
        const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, elem_ty, obj, &indices, 1, "idx");
        return C.LLVMBuildLoad2(s.lc.builder, elem_ty, elem_ptr, "load");
    }
    // Value array: extractvalue if constant index, else alloca+GEP
    const arr_ty = types_mod.resolveOrSlot(s.lc, obj_ty_name);
    const tmp = C.LLVMBuildAlloca(s.lc.builder, arr_ty, "arr_tmp");
    _ = C.LLVMBuildStore(s.lc.builder, obj, tmp);
    var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), index_val };
    const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, arr_ty, tmp, &idxs, 2, "elem_ptr");
    return C.LLVMBuildLoad2(s.lc.builder, elem_ty, elem_ptr, "elem");
}

fn lowerAssignment(s: *ExprState, asg: ast.Assignment) CodegenError!T.LLVMValueRef {
    const val = try lowerExpr(s, asg.right);
    if (asg.left.* == .primary and (asg.left.primary.kind == .identifier or asg.left.primary.kind == .register)) {
        if (s.locals.get(asg.left.primary.name)) |slot| {
            const slot_ty = C.LLVMGetAllocatedType(slot);
            _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, val, slot_ty), slot);
        } else if (s.lc.globals.get(asg.left.primary.name)) |slot| {
            const gty = C.LLVMGlobalGetValueType(slot);
            _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, val, gty), slot);
        }
    } else if (asg.left.* == .member) {
        const mem = asg.left.member;
        const obj_type_name = layout.unwrapTypeName(typeOf(s, mem.object));
        if (mem.property.* == .primary) {
            if (types_mod.getStructFieldIndex(s.lc, obj_type_name, mem.property.primary.name)) |idx| {
                const obj_ty = types_mod.resolveOrSlot(s.lc, obj_type_name);
                if (mem.object.* == .primary) {
                    if (s.locals.get(mem.object.primary.name)) |slot| {
                        const field_ptr = C.LLVMBuildStructGEP2(s.lc.builder, obj_ty, slot, idx, "fset");
                        const fty = C.LLVMGetElementType(C.LLVMTypeOf(field_ptr));
                        _ = fty;
                        const sd = s.lc.state.structs.get(obj_type_name).?;
                        const ft_name = sd.types.get(mem.property.primary.name) orelse "i64";
                        const ft = types_mod.resolveOrSlot(s.lc, ft_name);
                        _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, val, ft), field_ptr);
                    }
                }
            }
        }
    } else if (asg.left.* == .index and !asg.left.index.is_slice) {
        const obj = try lowerExpr(s, asg.left.index.object);
        const index_val = if (asg.left.index.index) |i| try lowerExpr(s, i) else return val;
        const elem_ty = C.LLVMTypeOf(val);
        if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMPointerTypeKind) {
            var indices = [_]T.LLVMValueRef{index_val};
            const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, elem_ty, obj, &indices, 1, "idxset");
            _ = C.LLVMBuildStore(s.lc.builder, val, elem_ptr);
        }
    }
    return val;
}

fn lowerBinary(s: *ExprState, bin: ast.Binary, node: *ast.Node) CodegenError!T.LLVMValueRef {
    const op = bin.operator;

    // Short-circuit && / ||
    if (std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "and")) {
        return try lowerShortCircuit(s, bin, node, true);
    }
    if (std.mem.eql(u8, op, "||") or std.mem.eql(u8, op, "or")) {
        return try lowerShortCircuit(s, bin, node, false);
    }

    var lhs = try lowerExpr(s, bin.left);
    var rhs = try lowerExpr(s, bin.right);
    const result_ty = llvmTypeOf(s, node);
    const t = typeOf(s, node);
    const operand_ty = if (std.mem.eql(u8, layout.unwrapTypeName(t), "bool") or std.mem.eql(u8, layout.unwrapTypeName(t), "u1"))
        types_mod.resolveOrSlot(s.lc, typeOf(s, bin.left))
    else
        result_ty;

    // For comparisons, cast both to left's type.
    if (isCmp(op)) {
        const lty = types_mod.resolveOrSlot(s.lc, typeOf(s, bin.left));
        lhs = types_mod.castTo(s.lc, lhs, lty);
        rhs = types_mod.castTo(s.lc, rhs, lty);
    } else {
        lhs = types_mod.castTo(s.lc, lhs, operand_ty);
        rhs = types_mod.castTo(s.lc, rhs, operand_ty);
    }

    const b = s.lc.builder;
    const is_float = types_mod.isFloatName(typeOf(s, bin.left));
    const is_unsigned = types_mod.isUnsignedName(typeOf(s, bin.left));

    if (std.mem.eql(u8, op, "+")) return if (is_float) C.LLVMBuildFAdd(b, lhs, rhs, "add") else C.LLVMBuildAdd(b, lhs, rhs, "add");
    if (std.mem.eql(u8, op, "-")) return if (is_float) C.LLVMBuildFSub(b, lhs, rhs, "sub") else C.LLVMBuildSub(b, lhs, rhs, "sub");
    if (std.mem.eql(u8, op, "*")) return if (is_float) C.LLVMBuildFMul(b, lhs, rhs, "mul") else C.LLVMBuildMul(b, lhs, rhs, "mul");
    if (std.mem.eql(u8, op, "/")) return if (is_float) C.LLVMBuildFDiv(b, lhs, rhs, "div") else if (is_unsigned) C.LLVMBuildUDiv(b, lhs, rhs, "div") else C.LLVMBuildSDiv(b, lhs, rhs, "div");
    if (std.mem.eql(u8, op, "%")) return if (is_float) C.LLVMBuildFRem(b, lhs, rhs, "rem") else if (is_unsigned) C.LLVMBuildURem(b, lhs, rhs, "rem") else C.LLVMBuildSRem(b, lhs, rhs, "rem");

    if (std.mem.eql(u8, op, "&")) return C.LLVMBuildAnd(b, lhs, rhs, "band");
    if (std.mem.eql(u8, op, "|")) return C.LLVMBuildOr(b, lhs, rhs, "bor");
    if (std.mem.eql(u8, op, "^")) return C.LLVMBuildXor(b, lhs, rhs, "xor");
    if (std.mem.eql(u8, op, "<<")) return C.LLVMBuildShl(b, lhs, rhs, "shl");
    if (std.mem.eql(u8, op, ">>")) return if (is_unsigned) C.LLVMBuildLShr(b, lhs, rhs, "shr") else C.LLVMBuildAShr(b, lhs, rhs, "shr");

    if (std.mem.eql(u8, op, "==")) return if (is_float) C.LLVMBuildFCmp(b, .LLVMRealOEQ, lhs, rhs, "eq") else C.LLVMBuildICmp(b, .LLVMIntEQ, lhs, rhs, "eq");
    if (std.mem.eql(u8, op, "!=")) return if (is_float) C.LLVMBuildFCmp(b, .LLVMRealONE, lhs, rhs, "neq") else C.LLVMBuildICmp(b, .LLVMIntNE, lhs, rhs, "neq");
    if (std.mem.eql(u8, op, "<")) return if (is_float) C.LLVMBuildFCmp(b, .LLVMRealOLT, lhs, rhs, "lt") else if (is_unsigned) C.LLVMBuildICmp(b, .LLVMIntULT, lhs, rhs, "lt") else C.LLVMBuildICmp(b, .LLVMIntSLT, lhs, rhs, "lt");
    if (std.mem.eql(u8, op, "<=")) return if (is_float) C.LLVMBuildFCmp(b, .LLVMRealOLE, lhs, rhs, "lte") else if (is_unsigned) C.LLVMBuildICmp(b, .LLVMIntULE, lhs, rhs, "lte") else C.LLVMBuildICmp(b, .LLVMIntSLE, lhs, rhs, "lte");
    if (std.mem.eql(u8, op, ">")) return if (is_float) C.LLVMBuildFCmp(b, .LLVMRealOGT, lhs, rhs, "gt") else if (is_unsigned) C.LLVMBuildICmp(b, .LLVMIntUGT, lhs, rhs, "gt") else C.LLVMBuildICmp(b, .LLVMIntSGT, lhs, rhs, "gt");
    if (std.mem.eql(u8, op, ">=")) return if (is_float) C.LLVMBuildFCmp(b, .LLVMRealOGE, lhs, rhs, "gte") else if (is_unsigned) C.LLVMBuildICmp(b, .LLVMIntUGE, lhs, rhs, "gte") else C.LLVMBuildICmp(b, .LLVMIntSGE, lhs, rhs, "gte");

    // pow: use LLVM intrinsics — llvm.pow.f64 for floats, llvm.powi.i64 for ints.
    if (std.mem.eql(u8, op, "**")) {
        if (is_float) {
            const f64_ty = s.lc.f64Ty();
            const lhs_f = types_mod.castTo(s.lc, lhs, f64_ty);
            const rhs_f = types_mod.castTo(s.lc, rhs, f64_ty);
            const pow_fn = ensurePowF64(s) catch return poison(s, node);
            var args = [_]T.LLVMValueRef{ lhs_f, rhs_f };
            var ptypes = [_]T.LLVMTypeRef{ f64_ty, f64_ty };
            const ft = C.LLVMFunctionType(f64_ty, &ptypes, 2, 0);
            const result = C.LLVMBuildCall2(b, ft, pow_fn, &args, 2, "pow");
            return types_mod.castTo(s.lc, result, result_ty);
        } else {
            const i64_ty = s.lc.i64Ty();
            const i32_ty = s.lc.i32Ty();
            const lhs_i = types_mod.castTo(s.lc, lhs, i64_ty);
            const rhs_i32 = types_mod.castTo(s.lc, rhs, i32_ty);
            const powi_fn = ensurePowiI64(s) catch return poison(s, node);
            var args = [_]T.LLVMValueRef{ lhs_i, rhs_i32 };
            var ptypes = [_]T.LLVMTypeRef{ i64_ty, i32_ty };
            const ft = C.LLVMFunctionType(i64_ty, &ptypes, 2, 0);
            const result = C.LLVMBuildCall2(b, ft, powi_fn, &args, 2, "powi");
            return types_mod.castTo(s.lc, result, result_ty);
        }
    }

    return error.UnsupportedOperator;
}

fn ensurePowF64(s: *ExprState) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get("llvm.pow.f64")) |f| return f;
    const f64_ty = s.lc.f64Ty();
    var params = [_]T.LLVMTypeRef{ f64_ty, f64_ty };
    const ft = C.LLVMFunctionType(f64_ty, &params, 2, 0);
    const f = C.LLVMAddFunction(s.lc.mod, "llvm.pow.f64", ft);
    try s.lc.functions.put("llvm.pow.f64", f);
    return f;
}

fn ensurePowiI64(s: *ExprState) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get("llvm.powi.i64.i32")) |f| return f;
    const i64_ty = s.lc.i64Ty();
    const i32_ty = s.lc.i32Ty();
    var params = [_]T.LLVMTypeRef{ i64_ty, i32_ty };
    const ft = C.LLVMFunctionType(i64_ty, &params, 2, 0);
    const f = C.LLVMAddFunction(s.lc.mod, "llvm.powi.i64.i32", ft);
    try s.lc.functions.put("llvm.powi.i64.i32", f);
    return f;
}


fn isCmp(op: []const u8) bool {
    return std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=");
}

fn lowerShortCircuit(s: *ExprState, bin: ast.Binary, node: *ast.Node, is_and: bool) CodegenError!T.LLVMValueRef {
    _ = node;
    const fn_val = C.LLVMGetBasicBlockParent(C.LLVMGetInsertBlock(s.lc.builder));
    const rhs_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "sc.rhs");
    const merge_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "sc.merge");

    const lhs = try lowerExpr(s, bin.left);
    const lhs_bb = C.LLVMGetInsertBlock(s.lc.builder);
    if (is_and) {
        _ = C.LLVMBuildCondBr(s.lc.builder, lhs, rhs_bb, merge_bb);
    } else {
        _ = C.LLVMBuildCondBr(s.lc.builder, lhs, merge_bb, rhs_bb);
    }

    C.LLVMPositionBuilderAtEnd(s.lc.builder, rhs_bb);
    const rhs = try lowerExpr(s, bin.right);
    const rhs_end = C.LLVMGetInsertBlock(s.lc.builder);
    _ = C.LLVMBuildBr(s.lc.builder, merge_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, merge_bb);
    const phi = C.LLVMBuildPhi(s.lc.builder, C.LLVMTypeOf(lhs), "sc");
    var vals = [_]T.LLVMValueRef{ lhs, rhs };
    var bbs = [_]T.LLVMBasicBlockRef{ lhs_bb, rhs_end };
    C.LLVMAddIncoming(phi, &vals, &bbs, 2);
    return phi;
}

fn lowerUnary(s: *ExprState, un: ast.Unary, node: *ast.Node) CodegenError!T.LLVMValueRef {
    const val = try lowerExpr(s, un.arg);
    const b = s.lc.builder;
    if (std.mem.eql(u8, un.operator, "-")) {
        if (types_mod.isFloatName(typeOf(s, un.arg))) return C.LLVMBuildFNeg(b, val, "neg");
        return C.LLVMBuildNeg(b, val, "neg");
    }
    if (std.mem.eql(u8, un.operator, "!")) return C.LLVMBuildNot(b, val, "not");
    if (std.mem.eql(u8, un.operator, "~")) return C.LLVMBuildNot(b, val, "bnot");
    if (std.mem.eql(u8, un.operator, "&")) {
        // Address of local: if primary, return its alloca
        if (un.arg.* == .primary) {
            if (s.locals.get(un.arg.primary.name)) |slot| return slot;
            if (s.lc.globals.get(un.arg.primary.name)) |slot| return slot;
        }
        return types_mod.castTo(s.lc, val, s.lc.ptrTy());
    }
    if (std.mem.eql(u8, un.operator, "*")) {
        return C.LLVMBuildLoad2(b, llvmTypeOf(s, node), val, "deref");
    }
    if (std.mem.eql(u8, un.operator, "const")) return val;
    return error.UnsupportedOperator;
}

fn lowerStructInit(s: *ExprState, si: ast.StructInit, node: *ast.Node) CodegenError!T.LLVMValueRef {
    const type_name = layout.unwrapTypeName(typeOf(s, node));
    const struct_ty = llvmTypeOf(s, node);

    var struct_val = C.LLVMGetUndef(struct_ty);
    for (si.fields) |field| {
        if (types_mod.getStructFieldIndex(s.lc, type_name, field.name)) |idx| {
            const field_val = try lowerExpr(s, field.value);
            struct_val = C.LLVMBuildInsertValue(s.lc.builder, struct_val, field_val, idx, "insert");
        }
    }
    return struct_val;
}

fn lowerArrayLiteral(s: *ExprState, al: ast.ArrayLiteral, node: *ast.Node) CodegenError!T.LLVMValueRef {
    const arr_ty = llvmTypeOf(s, node);
    // If type resolved to pointer (open slice), build a stack array of inferred length.
    if (C.LLVMGetTypeKind(arr_ty) == .LLVMPointerTypeKind) {
        if (al.elements.len == 0) return C.LLVMConstNull(s.lc.ptrTy());
        const first = try lowerExpr(s, al.elements[0]);
        const elem_ty = C.LLVMTypeOf(first);
        const stack_ty = C.LLVMArrayType(elem_ty, @intCast(al.elements.len));
        const tmp = C.LLVMBuildAlloca(s.lc.builder, stack_ty, "arrlit");
        {
            var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), C.LLVMConstInt(s.lc.i64Ty(), 0, 0) };
            const ep = C.LLVMBuildGEP2(s.lc.builder, stack_ty, tmp, &idxs, 2, "ep");
            _ = C.LLVMBuildStore(s.lc.builder, first, ep);
        }
        for (al.elements[1..], 1..) |elem, i| {
            const elem_val = try lowerExpr(s, elem);
            var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), C.LLVMConstInt(s.lc.i64Ty(), i, 0) };
            const ep = C.LLVMBuildGEP2(s.lc.builder, stack_ty, tmp, &idxs, 2, "ep");
            _ = C.LLVMBuildStore(s.lc.builder, elem_val, ep);
        }
        var zero = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), C.LLVMConstInt(s.lc.i64Ty(), 0, 0) };
        return C.LLVMBuildGEP2(s.lc.builder, stack_ty, tmp, &zero, 2, "arrptr");
    }
    var arr_val = C.LLVMGetUndef(arr_ty);
    for (al.elements, 0..) |elem, i| {
        const elem_val = try lowerExpr(s, elem);
        arr_val = C.LLVMBuildInsertValue(s.lc.builder, arr_val, elem_val, @intCast(i), "insert");
    }
    return arr_val;
}

fn lowerTry(s: *ExprState, te: ast.TryExpr, node: *ast.Node) CodegenError!T.LLVMValueRef {
    _ = node;
    // Passthrough for now; error unions are still soft.
    return try lowerExpr(s, te.expression);
}

fn lowerError(s: *ExprState, ee: ast.ErrorExpr) CodegenError!T.LLVMValueRef {
    // Represent error as i64 with bit 63 set; message ignored for AOT stub.
    _ = ee;
    return C.LLVMConstInt(s.lc.i64Ty(), @bitCast(@as(i64, std.math.minInt(i64))), 0);
}
