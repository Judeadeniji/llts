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
const path = @import("../expr/path.zig");
const natives = @import("../natives.zig");
const state_mod = @import("../state.zig");
const target = llvm.target;
const LlvmContext = context.LlvmContext;

pub const CodegenError = error{
    UnsupportedExpression,
    UnsupportedOperator,
    UndefinedVariable,
    InvalidLiteral,
    OutOfMemory,
    NoSpaceLeft,
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
    // Function bodies are typechecked before top-level declarations register
    // their globals, so a global referenced inside a function can be recorded
    // as unknown. Use the registered global type instead of falling to i64 —
    // but only when the name isn't shadowed by a local/param in the current
    // function (`abs(a)` must not inherit the type of a top-level `$a`).
    if (node.* == .primary and node.primary.kind == .identifier) {
        if (!s.locals.contains(node.primary.name)) {
            if (s.lc.state.global_types.get(node.primary.name)) |gt| {
                if (!std.mem.startsWith(u8, gt, "module:")) return gt;
            }
        }
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
        // `__O_RDONLY`-style constant natives (`pub $O_RDONLY = __O_RDONLY;`)
        // are referenced as 0-arg primaries — call the native to get the value.
        if (natives.isKnownNative(prim.name)) {
            if (natives.lookup(prim.name).?.params.len == 0) {
                return try callNativeArgs(s, prim.name, &.{}, node);
            }
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

/// Native `__arena_alloc_bytes(handle, n) -> i8*` — the arena backing
/// `@new(allocator, …)`, so `arena.deinit()` reclaims the memory.
fn ensureArenaAllocBytes(s: *ExprState) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get("__arena_alloc_bytes")) |f| return f;
    var params = [_]T.LLVMTypeRef{ s.lc.i64Ty(), s.lc.i64Ty() };
    const fn_ty = C.LLVMFunctionType(s.lc.ptrTy(), &params, 2, 0);
    const f = C.LLVMAddFunction(s.lc.mod, "__arena_alloc_bytes", fn_ty);
    try s.lc.functions.put("__arena_alloc_bytes", f);
    return f;
}

/// Extract the opaque `i64` arena handle from an `Arena { handle: int }`
/// value. If the allocator already lowers to an integer, pass it through.
fn extractArenaHandle(s: *ExprState, allocator_val: T.LLVMValueRef) T.LLVMValueRef {
    if (C.LLVMGetTypeKind(C.LLVMTypeOf(allocator_val)) == .LLVMStructTypeKind) {
        return C.LLVMBuildExtractValue(s.lc.builder, allocator_val, 0, "arena_handle");
    }
    return allocator_val;
}

/// String-ish type displays: `string`, `[]byte`, `[]u8`, fixed `[N]byte`, and
/// `"…"` string-literal singletons (how the typechecker displays `.str_lit`).
pub fn isStringTypeName(t: []const u8) bool {
    if (std.mem.eql(u8, t, "string") or
        std.mem.eql(u8, t, "[]byte") or
        std.mem.eql(u8, t, "[]u8") or
        (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"')) return true;
    // Fixed-size byte buffers like `[4]byte` are string-ish; nested arrays
    // (`[][]byte` = the typechecker's display of `[]string`) are NOT.
    return std.mem.startsWith(u8, t, "[") and
        std.mem.endsWith(u8, t, "byte") and
        std.mem.indexOfScalar(u8, t, ']') == std.mem.lastIndexOfScalar(u8, t, ']');
}

fn isBoolTypeName(t: []const u8) bool {
    return std.mem.eql(u8, t, "bool") or std.mem.eql(u8, t, "boolean") or std.mem.eql(u8, t, "u1");
}

fn lowerPrint(s: *ExprState, call: ast.Call) CodegenError!T.LLVMValueRef {
    const printf = try ensurePrintf(s);
    const printf_ty = C.LLVMGlobalGetValueType(printf);
    for (call.args) |arg| {
        const val = try lowerExpr(s, arg);
        const tname = typeOf(s, arg);
        if (types_mod.isFloatName(tname)) {
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%g ", "fmt");
            var args = [_]T.LLVMValueRef{ fmt, types_mod.castTo(s.lc, val, tname, s.lc.f64Ty()) };
            _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &args, 2, "");
        } else if (isBoolTypeName(layout.unwrapTypeName(tname))) {
            // bool → "true"/"false" (matches the VM's print formatting).
            const tstr = C.LLVMBuildGlobalStringPtr(s.lc.builder, "true", "tstr");
            const fstr = C.LLVMBuildGlobalStringPtr(s.lc.builder, "false", "fstr");
            const b = types_mod.castTo(s.lc, val, tname, s.lc.i1Ty());
            const sel = C.LLVMBuildSelect(s.lc.builder, b, tstr, fstr, "bstr");
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%s ", "fmt");
            var args = [_]T.LLVMValueRef{ fmt, sel };
            _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &args, 2, "");
        } else if (isStringTypeName(layout.unwrapTypeName(tname))) {
            // String values live in the bytecode VM as packed bytes; natively they
            // are pointers. String variables are stored as i64 (ptrtoint), so
            // restore the pointer before printf's `%s`.
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%s ", "fmt");
            const sval = if (C.LLVMGetTypeKind(C.LLVMTypeOf(val)) == .LLVMIntegerTypeKind)
                C.LLVMBuildIntToPtr(s.lc.builder, val, s.lc.ptrTy(), "str_ptr")
            else
                val;
            var args = [_]T.LLVMValueRef{ fmt, sval };
            _ = C.LLVMBuildCall2(s.lc.builder, printf_ty, printf, &args, 2, "");
        } else {
            const fmt = C.LLVMBuildGlobalStringPtr(s.lc.builder, "%lld ", "fmt");
            const as_i64 = types_mod.castTo(s.lc, val, tname, s.lc.i64Ty());
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
        return types_mod.castTo(s.lc, val, typeOf(s, call.args[1]), llvmTypeOf(s, node));
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
        // Runtime error ABI (src/runtime/builtins/util.zig): `__err_is` treats
        // negative values (negated error pointers, raw -errno rcs, the math
        // natives' minInt sentinel) and error-region pointers as errors.
        const val = try lowerExpr(s, call.args[0]);
        const as_i64 = if (C.LLVMGetTypeKind(C.LLVMTypeOf(val)) == .LLVMPointerTypeKind)
            C.LLVMBuildPtrToInt(s.lc.builder, val, s.lc.i64Ty(), "err_as_int")
        else
            val;
        const fn_val = try ensureErrFn(s, "__err_is", &.{s.lc.i64Ty()}, s.lc.i1Ty());
        const fn_ty = C.LLVMGlobalGetValueType(fn_val);
        var args = [_]T.LLVMValueRef{as_i64};
        return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, &args, 1, "iserr");
    }
    if (std.mem.eql(u8, name, "@new")) {
        // @new(allocator, value) — allocate in the caller's arena via the
        // native `__arena_alloc_bytes` runtime (not raw malloc), so that
        // `arena.deinit()` actually reclaims the memory (matches the VM).
        if (call.args.len < 2) return poison(s, node);
        const allocator_val = try lowerExpr(s, call.args[0]);
        const arena_handle = extractArenaHandle(s, allocator_val);
        const val = try lowerExpr(s, call.args[1]);
        const val_ty = C.LLVMTypeOf(val);
        const dl = target.LLVMGetModuleDataLayout(s.lc.mod);
        const sz = target.LLVMABISizeOfType(dl, val_ty);
        const alloc_bytes = try ensureArenaAllocBytes(s);
        const ab_ty = C.LLVMGlobalGetValueType(alloc_bytes);
        var args = [_]T.LLVMValueRef{ arena_handle, C.LLVMConstInt(s.lc.i64Ty(), sz, 0) };
        const ptr = C.LLVMBuildCall2(s.lc.builder, ab_ty, alloc_bytes, &args, 2, "new");
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
    // Module/static path: `mem.create(...)` → `"std/mem.lls::create"`.
    if (try path.tryResolveStaticPath(s.lc.state, call.callee)) |resolved| {
        if (s.lc.functions.get(resolved)) |fn_val| {
            // std.debug.printLn → printf-style (kept before the generic call).
            if (std.mem.endsWith(u8, resolved, "printLn")) return try lowerPrint(s, call);
            return try buildCall(s, fn_val, call, resolved);
        }
    }

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

    // `len(x)`: fixed arrays are compile-time constants; strings use `__strlen`;
    // open slices / native arrays use the count-prefix runtime (`arr[-1]`).
    if (std.mem.eql(u8, fn_name, "len")) {
        return try lowerLen(s, call, node);
    }

    // Native `__`-functions with known signatures (std wrappers call these).
    if (natives.isKnownNative(fn_name)) {
        return try lowerNativeCall(s, fn_name, call, node);
    }

    const fn_val = s.lc.functions.get(fn_name) orelse blk: {
        // External or not-yet-declared: declare variadic i64 stub returning node type.
        const fn_name_z = s.lc.allocator.dupeZ(u8, fn_name) catch return error.OutOfMemory;
        defer s.lc.allocator.free(fn_name_z);
        const ret = llvmTypeOf(s, node);
        const fn_ty = C.LLVMFunctionType(ret, null, 0, 1);
        const decl = C.LLVMAddFunction(s.lc.mod, fn_name_z, fn_ty);
        const duped_name = try s.lc.allocator.dupe(u8, fn_name);
        try s.lc.functions.put(duped_name, decl);
        break :blk decl;
    };

    return try buildCall(s, fn_val, call, fn_name);
}

/// Does `name`'s declaration end in a `...rest` param? Call sites must pack
/// their extra args into a native array before the call.
fn fnHasRestParam(state: *state_mod.CompilerState, name: []const u8) bool {
    const def = state.functions.get(name) orelse return false;
    if (def.node.* != .function_decl) return false;
    const params = switch (def.node.function_decl.params.*) {
        .params => |p| p.params,
        else => return false,
    };
    if (params.len == 0) return false;
    return params[params.len - 1].is_rest;
}

/// `len(x)` lowering: `[N]T` → constant N; open slices `[]T` → `__arrayLen`
/// (count-prefixed native arrays); strings / unknown pointers → `__strlen`.
fn lowerLen(s: *ExprState, call: ast.Call, node: *ast.Node) CodegenError!T.LLVMValueRef {
    if (call.args.len != 1) return poison(s, node);
    const arg_type = typeOf(s, call.args[0]);
    // Strings (the typechecker displays `string` as `[]byte`) are NUL-terminated
    // C strings — byte length via `__strlen`, NOT the count-prefixed arrays.
    if (isStringTypeName(arg_type)) return try lowerNativeCall(s, "__strlen", call, node);
    if (std.mem.startsWith(u8, arg_type, "[")) {
        if (std.mem.indexOfScalar(u8, arg_type, ']')) |rb| {
            if (rb > 1) {
                if (std.fmt.parseInt(u64, arg_type[1..rb], 10)) |n| {
                    _ = try lowerExpr(s, call.args[0]);
                    return C.LLVMConstInt(s.lc.i64Ty(), n, 0);
                } else |_| {}
            }
        }
        // Open slice `[]T` → count-prefixed native array.
        return try lowerNativeCall(s, "__arrayLen", call, node);
    }
    // String literal / variable / unknown pointer → byte length.
    return try lowerNativeCall(s, "__strlen", call, node);
}

/// Declare (once) a native function from the signature table and return its value.
fn nativeFnVal(s: *ExprState, name: []const u8) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get(name)) |fn_val| return fn_val;
    const sig = natives.lookup(name) orelse return error.UnsupportedExpression;
    const params = s.lc.allocator.alloc(T.LLVMTypeRef, sig.params.len) catch return error.OutOfMemory;
    defer s.lc.allocator.free(params);
    for (sig.params, 0..) |p, i| params[i] = types_mod.resolveOrSlot(s.lc, p);
    const ret_ty = types_mod.resolveOrSlot(s.lc, sig.ret);
    const fn_ty = C.LLVMFunctionType(ret_ty, if (sig.params.len > 0) params.ptr else null, @intCast(sig.params.len), 0);
    const name_z = s.lc.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer s.lc.allocator.free(name_z);
    const fn_val = C.LLVMAddFunction(s.lc.mod, name_z, fn_ty);
    const duped_name = try s.lc.allocator.dupe(u8, name);
    try s.lc.functions.put(duped_name, fn_val);
    return fn_val;
}

/// Lower a call to a `__`-native using its signature-table ABI (real param
/// types + return type instead of the variadic i64 stub).
fn lowerNativeCall(s: *ExprState, name: []const u8, call: ast.Call, node: *ast.Node) CodegenError!T.LLVMValueRef {
    return callNativeArgs(s, name, call.args, node);
}

/// Lower a call to a native given a slice of argument nodes. Variadic natives
/// (`__sys_open(path, flags[, mode])`) are declared with their FULL param
/// list; missing trailing args are zero-padded.
fn callNativeArgs(s: *ExprState, name: []const u8, args: []*ast.Node, node: *ast.Node) CodegenError!T.LLVMValueRef {
    _ = node;
    const fn_val = try nativeFnVal(s, name);
    const fn_ty = C.LLVMGlobalGetValueType(fn_val);
    const param_count: usize = @intCast(C.LLVMCountParamTypes(fn_ty));

    const argc = @max(args.len, param_count);
    const argv = s.lc.allocator.alloc(T.LLVMValueRef, argc) catch return error.OutOfMemory;
    defer s.lc.allocator.free(argv);
    var param_tys: []T.LLVMTypeRef = &.{};
    if (param_count > 0) {
        param_tys = s.lc.allocator.alloc(T.LLVMTypeRef, param_count) catch return error.OutOfMemory;
        C.LLVMGetParamTypes(fn_ty, param_tys.ptr);
    }
    defer if (param_count > 0) s.lc.allocator.free(param_tys);
    for (0..argc) |i| {
        if (i < args.len) {
            var v = try lowerExpr(s, args[i]);
            if (i < param_count) v = types_mod.castTo(s.lc, v, typeOf(s, args[i]), param_tys[i]);
            argv[i] = v;
        } else {
            argv[i] = C.LLVMConstNull(param_tys[i]);
        }
    }

    const ret_ty = C.LLVMGetReturnType(fn_ty);
    const name_z: [*:0]const u8 = if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) "" else "call";
    return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, argv.ptr, @intCast(argv.len), name_z);
}

/// Lower `call.args` against `fn_val`'s declared signature and emit the call.
/// When the callee declares a `...rest` param (e.g. `open(path, flags, ...rest)`
/// or `min(...args)`), the fixed args are passed as-is and the remaining args
/// are packed into a count-prefixed array (`arr[-1]` = count) passed as the
/// final argument. Packed elements are raw i64 — except for `min`/`max`,
/// which compare as f64 like the VM's `minMax`.
fn buildCall(s: *ExprState, fn_val: T.LLVMValueRef, call: ast.Call, fn_name: []const u8) CodegenError!T.LLVMValueRef {
    const fn_ty = C.LLVMGlobalGetValueType(fn_val);
    const param_count: usize = @intCast(C.LLVMCountParamTypes(fn_ty));

    if (fnHasRestParam(s.lc.state, fn_name)) {
        const fixed = if (param_count > 0) param_count - 1 else 0;
        const rest_start = @min(fixed, call.args.len);
        const elem_f64 = fnNameIsMinMax(fn_name);
        const arr = try packRestArray(s, call.args[rest_start..], elem_f64);
        const argv = s.lc.allocator.alloc(T.LLVMValueRef, param_count) catch return error.OutOfMemory;
        defer s.lc.allocator.free(argv);
        var param_tys: []T.LLVMTypeRef = &.{};
        if (param_count > 0) {
            param_tys = s.lc.allocator.alloc(T.LLVMTypeRef, param_count) catch return error.OutOfMemory;
            C.LLVMGetParamTypes(fn_ty, param_tys.ptr);
        }
        defer if (param_count > 0) s.lc.allocator.free(param_tys);
        var i: usize = 0;
        while (i < rest_start) : (i += 1) {
            var v = try lowerExpr(s, call.args[i]);
            if (i < param_count) v = types_mod.castTo(s.lc, v, typeOf(s, call.args[i]), param_tys[i]);
            argv[i] = v;
        }
        // Zero-pad missing fixed args (a wrapper called with too few args).
        while (i + 1 < param_count) : (i += 1) argv[i] = C.LLVMConstNull(param_tys[i]);
        argv[param_count - 1] = types_mod.castTo(s.lc, arr, "unknown", param_tys[param_count - 1]);
        const ret_ty = C.LLVMGetReturnType(fn_ty);
        const name_z: [*:0]const u8 = if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) "" else "call";
        return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, argv.ptr, @intCast(argv.len), name_z);
    }

    const argv = s.lc.allocator.alloc(T.LLVMValueRef, call.args.len) catch return error.OutOfMemory;
    defer s.lc.allocator.free(argv);
    var param_tys: []T.LLVMTypeRef = &.{};
    if (param_count > 0) {
        param_tys = s.lc.allocator.alloc(T.LLVMTypeRef, param_count) catch return error.OutOfMemory;
        C.LLVMGetParamTypes(fn_ty, param_tys.ptr);
    }
    defer if (param_count > 0) s.lc.allocator.free(param_tys);
    for (call.args, 0..) |arg, i| {
        var v = try lowerExpr(s, arg);
        if (i < param_count) v = types_mod.castTo(s.lc, v, typeOf(s, arg), param_tys[i]);
        argv[i] = v;
    }

    const ret_ty = C.LLVMGetReturnType(fn_ty);
    const name_z: [*:0]const u8 = if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) "" else "call";
    return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, argv.ptr, @intCast(argv.len), name_z);
}

fn fnNameIsMinMax(fn_name: []const u8) bool {
    return std.mem.eql(u8, fn_name, "min") or std.mem.eql(u8, fn_name, "max") or
        std.mem.endsWith(u8, fn_name, "::min") or std.mem.endsWith(u8, fn_name, "::max");
}

/// Pack `args` into a count-prefixed stack array. Slot 0 holds the element
/// count (as i64 bits, bitcast to f64 in f64 mode); the returned pointer
/// points at element 0 so `arr[-1]` reads the count back as an i64. In f64
/// mode (min/max) int elements are widened to f64 like the VM's `minMax`.
fn packRestArray(s: *ExprState, args: []*ast.Node, elem_f64: bool) CodegenError!T.LLVMValueRef {
    const n = args.len;
    const elem_ty = if (elem_f64) s.lc.f64Ty() else s.lc.i64Ty();
    const arr_ty = C.LLVMArrayType(elem_ty, @intCast(n + 1));
    const tmp = C.LLVMBuildAlloca(s.lc.builder, arr_ty, "restarr");

    const count_i = C.LLVMConstInt(s.lc.i64Ty(), @intCast(n), 0);
    const count_v = if (elem_f64) C.LLVMBuildBitCast(s.lc.builder, count_i, elem_ty, "restcount") else count_i;
    {
        var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), C.LLVMConstInt(s.lc.i64Ty(), 0, 0) };
        const ep = C.LLVMBuildGEP2(s.lc.builder, arr_ty, tmp, &idxs, 2, "ep0");
        _ = C.LLVMBuildStore(s.lc.builder, count_v, ep);
    }
    for (args, 0..) |arg, i| {
        const v = try lowerExpr(s, arg);
        const f = types_mod.castTo(s.lc, v, typeOf(s, arg), elem_ty);
        var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), C.LLVMConstInt(s.lc.i64Ty(), i + 1, 0) };
        const ep = C.LLVMBuildGEP2(s.lc.builder, arr_ty, tmp, &idxs, 2, "ep");
        _ = C.LLVMBuildStore(s.lc.builder, f, ep);
    }
    var zero = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), C.LLVMConstInt(s.lc.i64Ty(), 1, 0) };
    return C.LLVMBuildGEP2(s.lc.builder, arr_ty, tmp, &zero, 2, "restptr");
}

fn lowerMethodCall(s: *ExprState, call: ast.Call, node: *ast.Node) CodegenError!?T.LLVMValueRef {
    const mem = call.callee.member;
    if (mem.property.* != .primary) return null;
    const method_name = mem.property.primary.name;
    const obj_type_name = layout.unwrapTypeName(typeOf(s, mem.object));
    // Strip `*` / `?` receiver prefixes: an unannotated `self` is `*Struct`
    // (by-reference receiver), but the method is declared as `Struct::name`
    // (module structs keep their `module/path.lls::` qualifier).
    var stripped = obj_type_name;
    // Also strip `module:` prefix for module imports: `module:std/list.lls` → `std/list.lls`.
    if (std.mem.startsWith(u8, stripped, "module:")) stripped = stripped[7..];
    while (stripped.len > 0 and (stripped[0] == '*' or stripped[0] == '?')) stripped = stripped[1..];

    var mangled_buf: [256]u8 = undefined;
    const mangled = std.fmt.bufPrint(&mangled_buf, "{s}::{s}", .{ stripped, method_name }) catch return null;

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
        // Receiver (arg 0): coerce to the declared `self` type.
        argv[0] = coerceReceiver(s, mem.object, obj_val, param_tys[0]);
        for (argv[1..], 0..) |*a, i| {
            if (i + 1 < param_count) {
                const arg_type_name = typeOf(s, call.args[i]);
                a.* = types_mod.castTo(s.lc, a.*, arg_type_name, param_tys[i + 1]);
            }
        }
    }
    const ret_ty = C.LLVMGetReturnType(fn_ty);
    const name_z: [*:0]const u8 = if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) "" else "mcall";
    const res = C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, argv.ptr, @intCast(argv.len), name_z);
    _ = node;
    return res;
}

/// Coerce a method receiver to the declared `self` parameter type.
/// An unannotated `self` is `*Struct` (by-reference): the caller passes the
/// object's address (its global slot / local alloca when named, else a
/// materialized copy). Annotated `self: T` passes the struct value. This also
/// bridges the legacy pointer-as-int receiver.
fn coerceReceiver(s: *ExprState, object: *ast.Node, obj_val: T.LLVMValueRef, self_ty: T.LLVMTypeRef) T.LLVMValueRef {
    const obj_ty = C.LLVMTypeOf(obj_val);
    if (obj_ty == self_ty) return obj_val;
    const pk = C.LLVMGetTypeKind(self_ty);
    const ok = C.LLVMGetTypeKind(obj_ty);
    if (pk == .LLVMPointerTypeKind) {
        // By-reference receiver: pass the object's address.
        if (ok == .LLVMStructTypeKind) {
            if (object.* == .primary) {
                if (s.locals.get(object.primary.name)) |slot| return slot;
                if (s.lc.globals.get(object.primary.name)) |gslot| return gslot;
            }
            const temp = C.LLVMBuildAlloca(s.lc.builder, obj_ty, "self_copy");
            _ = C.LLVMBuildStore(s.lc.builder, obj_val, temp);
            return temp;
        }
        if (ok == .LLVMIntegerTypeKind) {
            // Pointer-as-int receiver (e.g. `factory()` returning ptrtoint).
            return C.LLVMBuildIntToPtr(s.lc.builder, obj_val, s.lc.ptrTy(), "self_ptr");
        }
        return obj_val; // already a pointer
    }
    if (ok == .LLVMStructTypeKind and pk == .LLVMIntegerTypeKind) {
        // `Arena { handle: i64 }`-style receiver → pass the handle.
        return C.LLVMBuildExtractValue(s.lc.builder, obj_val, 0, "self_handle");
    }
    if (ok == .LLVMPointerTypeKind and pk == .LLVMStructTypeKind) {
        return C.LLVMBuildLoad2(s.lc.builder, self_ty, obj_val, "self_val");
    }
    return obj_val;
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

    // Module const: `math.PI` → the qualified global `std/math.lls::PI`.
    if (try path.tryResolveStaticPath(s.lc.state, node)) |static_path| {
        if (s.lc.globals.get(static_path)) |gslot| {
            const gty = C.LLVMGlobalGetValueType(gslot);
            return C.LLVMBuildLoad2(s.lc.builder, gty, gslot, "mconst");
        }
    }

    const obj_val = try lowerExpr(s, mem_node.object);
    const obj_type_name = layout.unwrapTypeName(typeOf(s, mem_node.object));

    if (mem_node.property.* == .primary and mem_node.property.primary.kind == .identifier) {
        const field_name = mem_node.property.primary.name;
        const obj_struct_name = types_mod.unwrapStructName(obj_type_name);
        if (types_mod.getStructFieldIndex(s.lc, obj_struct_name, field_name)) |idx| {
            const obj_ty = types_mod.resolveOrSlot(s.lc, obj_struct_name);
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
        // Error `.code` / `.payload` → the runtime error ABI. (Real struct
        // fields named `code`/`payload` win above; only non-struct receivers
        // — error values, strings — land here.)
        if (std.mem.eql(u8, field_name, "code") or std.mem.eql(u8, field_name, "payload")) {
            const as_i64 = if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj_val)) == .LLVMPointerTypeKind)
                C.LLVMBuildPtrToInt(s.lc.builder, obj_val, s.lc.i64Ty(), "err_as_int")
            else
                obj_val;
            const fn_name = if (std.mem.eql(u8, field_name, "code")) "__err_code" else "__err_payload";
            const fn_val = try ensureErrFn(s, fn_name, &.{s.lc.i64Ty()}, s.lc.ptrTy());
            const fn_ty = C.LLVMGlobalGetValueType(fn_val);
            var args = [_]T.LLVMValueRef{as_i64};
            return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, &args, 1, "errmember");
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
        return types_mod.castTo(s.lc, obj, typeOf(s, idx.object), llvmTypeOf(s, node));
    }
    const index_val = if (idx.index) |i| try lowerExpr(s, i) else return poison(s, node);
    const obj_ty_name = typeOf(s, idx.object);
    const elem_ty = llvmTypeOf(s, node);

    if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMPointerTypeKind) {
        var indices = [_]T.LLVMValueRef{index_val};
        const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, elem_ty, obj, &indices, 1, "idx");
        return C.LLVMBuildLoad2(s.lc.builder, elem_ty, elem_ptr, "load");
    }
    
    // If it's an integer, assume it's a dynamic pointer (like from buffer.lls or unknown).
    if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMIntegerTypeKind) {
        const ptr_val = C.LLVMBuildIntToPtr(s.lc.builder, obj, s.lc.ptrTy(), "dyn_ptr");
        var indices = [_]T.LLVMValueRef{index_val};
        const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, elem_ty, ptr_val, &indices, 1, "idx");
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
    const is_null = asg.right.* == .literal and asg.right.literal.literal_type == .@"null";
    const val = if (is_null) null else try lowerExpr(s, asg.right);

    if (asg.left.* == .primary and (asg.left.primary.kind == .identifier or asg.left.primary.kind == .register)) {
        if (s.locals.get(asg.left.primary.name)) |slot| {
            const slot_ty = C.LLVMGetAllocatedType(slot);
            const v = val orelse C.LLVMConstNull(slot_ty);
            const r_ty_name = if (is_null) "null" else typeOf(s, asg.right);
            _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, v, r_ty_name, slot_ty), slot);
        } else if (s.lc.globals.get(asg.left.primary.name)) |slot| {
            const gty = C.LLVMGlobalGetValueType(slot);
            const v = val orelse C.LLVMConstNull(gty);
            const r_ty_name = if (is_null) "null" else typeOf(s, asg.right);
            _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, v, r_ty_name, gty), slot);
        }
    } else if (asg.left.* == .member) {
        const mem = asg.left.member;
        const obj_type_name = layout.unwrapTypeName(typeOf(s, mem.object));
        if (mem.property.* == .primary) {
            const obj_struct_name = types_mod.unwrapStructName(obj_type_name);
            if (types_mod.getStructFieldIndex(s.lc, obj_struct_name, mem.property.primary.name)) |idx| {
                const obj_ty = types_mod.resolveOrSlot(s.lc, obj_struct_name);
                const sd = s.lc.state.structs.get(obj_struct_name).?;
                const ft_name = sd.types.get(mem.property.primary.name) orelse "i64";
                const ft = types_mod.resolveOrSlot(s.lc, ft_name);
                const v = val orelse C.LLVMConstNull(ft);
                const r_ty_name = if (is_null) "null" else typeOf(s, asg.right);
                const field_ptr = blk: {
                    if (mem.object.* == .primary) {
                        if (s.locals.get(mem.object.primary.name)) |slot| {
                            const slot_ty = C.LLVMGetAllocatedType(slot);
                            const base = if (C.LLVMGetTypeKind(slot_ty) == .LLVMPointerTypeKind)
                                C.LLVMBuildLoad2(s.lc.builder, slot_ty, slot, "self_p")
                            else
                                slot;
                            break :blk C.LLVMBuildStructGEP2(s.lc.builder, obj_ty, base, idx, "fset");
                        }
                        if (s.lc.globals.get(mem.object.primary.name)) |slot| {
                            const gty = C.LLVMGlobalGetValueType(slot);
                            const base = if (C.LLVMGetTypeKind(gty) == .LLVMPointerTypeKind)
                                C.LLVMBuildLoad2(s.lc.builder, gty, slot, "self_p")
                            else
                                slot;
                            break :blk C.LLVMBuildStructGEP2(s.lc.builder, obj_ty, base, idx, "fset");
                        }
                    }
                    const obj = try lowerExpr(s, mem.object);
                    const base = if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMPointerTypeKind)
                        obj
                    else blk2: {
                        const tmp = C.LLVMBuildAlloca(s.lc.builder, obj_ty, "fset_tmp");
                        _ = C.LLVMBuildStore(s.lc.builder, obj, tmp);
                        break :blk2 tmp;
                    };
                    break :blk C.LLVMBuildStructGEP2(s.lc.builder, obj_ty, base, idx, "fset");
                };
                _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, v, r_ty_name, ft), field_ptr);
            }
        }
    } else if (asg.left.* == .index and !asg.left.index.is_slice) {
        const obj = try lowerExpr(s, asg.left.index.object);
        const index_val = if (asg.left.index.index) |i| try lowerExpr(s, i) else return val orelse C.LLVMConstNull(s.lc.i64Ty());
        
        // Find element type from the object type name if val is null, else use val's type
        const elem_ty = if (is_null) blk: {
            const arr_ty = types_mod.resolveOrSlot(s.lc, typeOf(s, asg.left.index.object));
            break :blk C.LLVMGetElementType(arr_ty) orelse s.lc.i64Ty();
        } else C.LLVMTypeOf(val.?);

        if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMPointerTypeKind) {
            var indices = [_]T.LLVMValueRef{index_val};
            const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, elem_ty, obj, &indices, 1, "idxset");
            const v = val orelse C.LLVMConstNull(elem_ty);
            _ = C.LLVMBuildStore(s.lc.builder, v, elem_ptr);
        } else if (C.LLVMGetTypeKind(C.LLVMTypeOf(obj)) == .LLVMIntegerTypeKind) {
            const ptr_val = C.LLVMBuildIntToPtr(s.lc.builder, obj, s.lc.ptrTy(), "dyn_ptr");
            var indices = [_]T.LLVMValueRef{index_val};
            const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, elem_ty, ptr_val, &indices, 1, "idxset");
            const v = val orelse C.LLVMConstNull(elem_ty);
            _ = C.LLVMBuildStore(s.lc.builder, v, elem_ptr);
        } else {
            // Handle array type if needed
            const arr_ty = types_mod.resolveOrSlot(s.lc, typeOf(s, asg.left.index.object));
            const tmp = C.LLVMBuildAlloca(s.lc.builder, arr_ty, "arr_tmp");
            _ = C.LLVMBuildStore(s.lc.builder, obj, tmp);
            var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), index_val };
            const elem_ptr = C.LLVMBuildGEP2(s.lc.builder, arr_ty, tmp, &idxs, 2, "elem_ptr");
            const v = val orelse C.LLVMConstNull(elem_ty);
            _ = C.LLVMBuildStore(s.lc.builder, v, elem_ptr);
        }
    }
    return val orelse C.LLVMConstNull(s.lc.i64Ty());
}

fn lowerBinary(s: *ExprState, bin: ast.Binary, node: *ast.Node) CodegenError!T.LLVMValueRef {
    const op = bin.operator;

    // String equality: `==` / `!=` on string values compares contents via
    // `__eql` (pointer equality would be wrong — each native result is a
    // fresh heap copy).
    if ((std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) and
        isStringTypeName(typeOf(s, bin.left)) and isStringTypeName(typeOf(s, bin.right)))
    {
        const lhs = try lowerExpr(s, bin.left);
        const rhs = try lowerExpr(s, bin.right);
        const l = if (C.LLVMGetTypeKind(C.LLVMTypeOf(lhs)) == .LLVMIntegerTypeKind)
            C.LLVMBuildIntToPtr(s.lc.builder, lhs, s.lc.ptrTy(), "lstr")
        else
            lhs;
        const r = if (C.LLVMGetTypeKind(C.LLVMTypeOf(rhs)) == .LLVMIntegerTypeKind)
            C.LLVMBuildIntToPtr(s.lc.builder, rhs, s.lc.ptrTy(), "rstr")
        else
            rhs;
        const eq = try strEql(s, l, r);
        if (std.mem.eql(u8, op, "!=")) return C.LLVMBuildNot(s.lc.builder, eq, "strneq");
        return eq;
    }

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
        lhs = types_mod.castTo(s.lc, lhs, typeOf(s, bin.left), lty);
        rhs = types_mod.castTo(s.lc, rhs, typeOf(s, bin.right), lty);
    } else {
        lhs = types_mod.castTo(s.lc, lhs, typeOf(s, bin.left), operand_ty);
        rhs = types_mod.castTo(s.lc, rhs, typeOf(s, bin.right), operand_ty);
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
            const lhs_f = types_mod.castTo(s.lc, lhs, typeOf(s, bin.left), f64_ty);
            const rhs_f = types_mod.castTo(s.lc, rhs, typeOf(s, bin.right), f64_ty);
            const pow_fn = ensurePowF64(s) catch return poison(s, node);
            var args = [_]T.LLVMValueRef{ lhs_f, rhs_f };
            var ptypes = [_]T.LLVMTypeRef{ f64_ty, f64_ty };
            const ft = C.LLVMFunctionType(f64_ty, &ptypes, 2, 0);
            const result = C.LLVMBuildCall2(b, ft, pow_fn, &args, 2, "pow");
            return types_mod.castTo(s.lc, result, "f64", result_ty);
        } else {
            const i64_ty = s.lc.i64Ty();
            const i32_ty = s.lc.i32Ty();
            const lhs_i = types_mod.castTo(s.lc, lhs, typeOf(s, bin.left), i64_ty);
            const rhs_i32 = types_mod.castTo(s.lc, rhs, typeOf(s, bin.right), i32_ty);
            const powi_fn = ensurePowiI64(s) catch return poison(s, node);
            var args = [_]T.LLVMValueRef{ lhs_i, rhs_i32 };
            var ptypes = [_]T.LLVMTypeRef{ i64_ty, i32_ty };
            const ft = C.LLVMFunctionType(i64_ty, &ptypes, 2, 0);
            const result = C.LLVMBuildCall2(b, ft, powi_fn, &args, 2, "powi");
            return types_mod.castTo(s.lc, result, "i64", result_ty);
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
        return types_mod.castTo(s.lc, val, typeOf(s, un.arg), s.lc.ptrTy());
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

/// Declare (once) a runtime helper with an exact LLVM signature.
fn ensureErrFn(s: *ExprState, name: []const u8, params: []const T.LLVMTypeRef, ret: T.LLVMTypeRef) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get(name)) |f| return f;
    const fn_ty = C.LLVMFunctionType(ret, if (params.len > 0) @constCast(params.ptr) else null, @intCast(params.len), 0);
    const name_z = s.lc.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer s.lc.allocator.free(name_z);
    const f = C.LLVMAddFunction(s.lc.mod, name_z, fn_ty);
    const duped = s.lc.allocator.dupe(u8, name) catch return error.OutOfMemory;
    try s.lc.functions.put(duped, f);
    return f;
}

/// `__eql(a, b) -> bool` — C-string content equality (already a native in the
/// signature table; this only ensures the declaration exists for synthetic calls).
fn ensureEql(s: *ExprState) CodegenError!T.LLVMValueRef {
    if (s.lc.functions.get("__eql")) |f| return f;
    var params = [_]T.LLVMTypeRef{ s.lc.ptrTy(), s.lc.ptrTy() };
    const fn_ty = C.LLVMFunctionType(s.lc.i1Ty(), &params, 2, 0);
    const f = C.LLVMAddFunction(s.lc.mod, "__eql", fn_ty);
    const duped = s.lc.allocator.dupe(u8, "__eql") catch return error.OutOfMemory;
    try s.lc.functions.put(duped, f);
    return f;
}

pub fn strEql(s: *ExprState, a: T.LLVMValueRef, b: T.LLVMValueRef) CodegenError!T.LLVMValueRef {
    const fn_val = try ensureEql(s);
    const fn_ty = C.LLVMGlobalGetValueType(fn_val);
    var args = [_]T.LLVMValueRef{ a, b };
    return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, &args, 2, "streq");
}

/// `error(name, payload)` → `__err_new(code, payload)` returning a negated
/// error pointer (negative i64) that `@isError` / `.code` / `.payload` decode.
fn lowerError(s: *ExprState, ee: ast.ErrorExpr) CodegenError!T.LLVMValueRef {
    if (ee.args.len == 0) {
        // Bare `error` — the legacy minInt sentinel (still detected by __err_is).
        return C.LLVMConstInt(s.lc.i64Ty(), @bitCast(@as(i64, std.math.minInt(i64))), 0);
    }
    const code = try lowerExpr(s, ee.args[0]);
    const payload_raw = if (ee.args.len > 1) try lowerExpr(s, ee.args[1]) else C.LLVMConstNull(s.lc.i64Ty());
    const payload = if (C.LLVMGetTypeKind(C.LLVMTypeOf(payload_raw)) == .LLVMPointerTypeKind)
        C.LLVMBuildPtrToInt(s.lc.builder, payload_raw, s.lc.i64Ty(), "err_payload")
    else
        payload_raw;
    const fn_val = try ensureErrFn(s, "__err_new", &.{ s.lc.ptrTy(), s.lc.i64Ty() }, s.lc.i64Ty());
    const fn_ty = C.LLVMGlobalGetValueType(fn_val);
    var args = [_]T.LLVMValueRef{ code, payload };
    return C.LLVMBuildCall2(s.lc.builder, fn_ty, fn_val, &args, 2, "errnew");
}
