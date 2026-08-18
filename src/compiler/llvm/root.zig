//! LLVM backend entry point.
//!
//! Lowers AST + CompilerState (including per-node types) into an LLVM module.

const std = @import("std");
const llvm = @import("llvm");
const T = llvm.types;
const C = llvm.core;
const ast = @import("../../ast/root.zig");
const context = @import("context.zig");
const stmt_mod = @import("stmt.zig");
const types_mod = @import("types.zig");
const from_ast = @import("../typecheck/from_ast.zig");
const typecheck = @import("../typecheck/root.zig");
const state_mod = @import("../state.zig");
const reachability = @import("../reachability.zig");
const layout = @import("../layout.zig");

pub const LlvmContext = context.LlvmContext;
pub const CodegenError = stmt_mod.StmtError || error{UnsupportedTopLevel};

/// Lower an entire parsed `Document` into LLVM IR stored in `lc`.
pub fn codegen(lc: *LlvmContext, doc: *ast.Document) CodegenError!void {
    var reach = reachability.compute(lc.state, doc) catch return error.UnsupportedTopLevel;
    defer reach.deinit();

    // `analyze` typechecks only the main document; imported module function
    // bodies are parsed but untyped. Typecheck every reachable function so the
    // backend sees per-node types (`self` receivers, field types, ...). Run to
    // a fixpoint: wrappers that call other wrappers (`fs.stat` → `cwd.stat`)
    // need their callees' inferred return types first, and the functions map
    // iterates in an unspecified order.
    {
        var prev_untyped: usize = std.math.maxInt(usize);
        while (true) {
            var untyped: usize = 0;
            var fit = lc.state.functions.iterator();
            while (fit.next()) |e| {
                const name = e.key_ptr.*;
                if (!reach.isFunctionReachable(name)) continue;
                const def = e.value_ptr.*;
                if (def.node.* != .function_decl) continue;
                if (std.mem.eql(u8, def.node.loc().path, doc.path)) continue; // already done by analyze
                const has_ret = def.return_type != null or def.node.function_decl.return_type != null;
                if (!has_ret) {
                    untyped += 1;
                    typecheck.typecheckFunction(lc.state, &def.node.function_decl) catch return error.UnsupportedTopLevel;
                }
            }
            if (untyped == 0 or untyped >= prev_untyped) break;
            prev_untyped = untyped;
        }
    }

    // Re-typecheck the main document now that module functions carry their
    // inferred return types. The first pass (in `compile`) ran before module
    // bodies were typed, so top-level declarations that call std wrappers
    // (`$arr = fs.stat(…)`) recorded `unknown` — leaving globals and index
    // element types at i64 in the emitted IR. `recordExprType` keeps the
    // first-recorded type, so the stale entries must be cleared first.
    lc.state.type_of_results.clearRetainingCapacity();
    typecheck.typecheck(lc.state, doc) catch return error.UnsupportedTopLevel;

    // Data layout needed for @sizeOf / @new.
    _ = C.LLVMSetTarget(lc.mod, "x86_64-unknown-linux-gnu");

    // Declare every known function (free + Struct::method) with real ABI.
    var fit = lc.state.functions.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        if (!reach.isFunctionReachable(name)) continue;
        const def = e.value_ptr.*;
        try declareFunctionFromDef(lc, name, def);
    }

    // Also declare any top-level function_decl not yet in the map (defensive).
    for (doc.statements) |node| {
        if (node.* == .function_decl) {
            if (!reach.isFunctionReachable(node.function_decl.name)) continue;
            try declareFunction(lc, node.function_decl.name, &node.function_decl);
        }
        if (node.* == .struct_decl) {
            for (node.struct_decl.methods) |m| {
                if (m.* == .function_decl) {
                    var buf: [256]u8 = undefined;
                    const mangled = std.fmt.bufPrint(&buf, "{s}::{s}", .{ node.struct_decl.name, m.function_decl.name }) catch continue;
                    if (!reach.isFunctionReachable(mangled)) continue;
                    try declareFunction(lc, mangled, &m.function_decl);
                }
            }
        }
    }

    // Declare typed globals (null init; stores happen in __llts_main).
    try declareGlobals(lc, &reach);

    // Emit function bodies from CompilerState (covers methods + free funcs).
    var emitted = std.StringHashMap(void).init(lc.allocator);
    defer emitted.deinit();

    var fit2 = lc.state.functions.iterator();
    while (fit2.next()) |e| {
        const name = e.key_ptr.*;
        if (!reach.isFunctionReachable(name)) continue;
        const def = e.value_ptr.*;
        if (emitted.contains(name)) continue;
        try emitted.put(name, {});
        try lowerFunctionFromDef(lc, name, def);
    }

    for (doc.statements) |node| {
        if (node.* == .function_decl) {
            if (!reach.isFunctionReachable(node.function_decl.name)) continue;
            if (!emitted.contains(node.function_decl.name)) {
                try lowerFunction(lc, node.function_decl.name, &node.function_decl);
            }
        }
        if (node.* == .struct_decl) {
            for (node.struct_decl.methods) |m| {
                if (m.* != .function_decl) continue;
                var buf: [256]u8 = undefined;
                const mangled = std.fmt.bufPrint(&buf, "{s}::{s}", .{ node.struct_decl.name, m.function_decl.name }) catch continue;
                if (!reach.isFunctionReachable(mangled)) continue;
                if (!emitted.contains(mangled)) {
                    try lowerFunction(lc, mangled, &m.function_decl);
                }
            }
        }
    }

    // Lower imported module function bodies that weren't reached above.
    for (lc.state.module_docs.items) |mdoc| {
        for (mdoc.statements) |node| {
            if (node.* == .function_decl) {
                if (!reach.isFunctionReachable(node.function_decl.name)) continue;
                if (lc.functions.contains(node.function_decl.name) and !emitted.contains(node.function_decl.name)) {
                    try emitted.put(node.function_decl.name, {});
                    try lowerFunction(lc, node.function_decl.name, &node.function_decl);
                }
            }
        }
    }

    // Synthesize @__llts_main for top-level statements.
    const llts_main_ty = C.LLVMFunctionType(lc.voidTy(), null, 0, 0);
    const llts_main_val = C.LLVMAddFunction(lc.mod, "__llts_main", llts_main_ty);
    const entry_bb = C.LLVMAppendBasicBlockInContext(lc.ctx, llts_main_val, "entry");
    C.LLVMPositionBuilderAtEnd(lc.builder, entry_bb);

    var ss = stmt_mod.StmtState.init(lc, llts_main_val);
    defer ss.deinit();

    for (doc.statements) |node| {
        switch (node.*) {
            .function_decl, .struct_decl, .enum_decl, .type_decl, .error_decl, .extern_decl => continue,
            else => {},
        }
        if (reach.shouldEmitTopLevel(doc, node)) {
            try stmt_mod.lowerStmt(&ss, node);
        }
    }
    _ = C.LLVMBuildRetVoid(lc.builder);

    // Synthesize C main(i32 argc, [*.][*:0]u8 argv). Store argc/argv
    // into globals so the native `__args()` can read them.
    if (lc.functions.get("main")) |user_main| {
        const user_main_name_z = lc.allocator.dupeZ(u8, "llts_user_main") catch return error.OutOfMemory;
        defer lc.allocator.free(user_main_name_z);
        C.LLVMSetValueName2(user_main, user_main_name_z, "llts_user_main".len);
    }
    const c_main_param_tys = [_]T.LLVMTypeRef{ lc.i32Ty(), C.LLVMPointerType(lc.ptrTy(), 0) };
    const c_main_ty = C.LLVMFunctionType(lc.i32Ty(), @constCast(@ptrCast(&c_main_param_tys)), 2, 0);
    const c_main_val = C.LLVMAddFunction(lc.mod, "main", c_main_ty);
    const c_main_entry = C.LLVMAppendBasicBlockInContext(lc.ctx, c_main_val, "entry");
    C.LLVMPositionBuilderAtEnd(lc.builder, c_main_entry);
    // Store argc/argv into globals for __args().
    const argc_global = C.LLVMAddGlobal(lc.mod, lc.i32Ty(), "__argc_global");
    C.LLVMSetInitializer(argc_global, C.LLVMConstInt(lc.i32Ty(), 0, 0));
    const argv_global = C.LLVMAddGlobal(lc.mod, C.LLVMPointerType(lc.ptrTy(), 0), "__argv_global");
    C.LLVMSetInitializer(argv_global, C.LLVMConstNull(C.LLVMPointerType(lc.ptrTy(), 0)));
    const argc_val = C.LLVMGetParam(c_main_val, 0);
    const argv_val = C.LLVMGetParam(c_main_val, 1);
    _ = C.LLVMBuildStore(lc.builder, argc_val, argc_global);
    _ = C.LLVMBuildStore(lc.builder, argv_val, argv_global);

    _ = C.LLVMBuildCall2(lc.builder, llts_main_ty, llts_main_val, null, 0, "");

    if (lc.functions.get("main")) |user_main| {
        const user_main_ty = C.LLVMGlobalGetValueType(user_main);
        _ = C.LLVMBuildCall2(lc.builder, user_main_ty, user_main, null, 0, "");
    }

    _ = C.LLVMBuildRet(lc.builder, C.LLVMConstInt(lc.i32Ty(), 0, 0));
}

fn declareGlobals(lc: *LlvmContext, reach: *const reachability.Result) CodegenError!void {
    var g_it = lc.state.global_vars.iterator();
    while (g_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!reach.globals.contains(name)) continue;
        try addGlobal(lc, name);
    }
    var c_it = lc.state.global_consts.iterator();
    while (c_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!reach.globals.contains(name)) continue;
        if (!lc.globals.contains(name)) try addGlobal(lc, name);
    }
}

fn addGlobal(lc: *LlvmContext, name: []const u8) CodegenError!void {
    if (lc.globals.contains(name)) return;
    const ty_name = lc.state.global_types.get(name) orelse "i64";
    // Skip module handles
    if (std.mem.startsWith(u8, ty_name, "module:")) return;

    const ty = types_mod.resolveOrSlot(lc, ty_name);
    const name_z = lc.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer lc.allocator.free(name_z);
    const global = C.LLVMAddGlobal(lc.mod, ty, name_z);
    C.LLVMSetInitializer(global, C.LLVMConstNull(ty));
    try lc.globals.put(name, global);
}


/// Resolve the type of param `i` of a function named `name`. For a
/// `Struct::method` whose receiver param is named `self`, an unannotated
/// `self` is `*Struct` (pointer — the receiver is passed by reference, matching
/// the typechecker's `resolveMethodSelfType`); other params (and annotated
/// receivers) fall back to `resolveParamType`.
fn resolveSelfParamType(lc: *LlvmContext, name: []const u8, fn_decl: *const ast.FunctionDecl, params: []ast.Param, i: usize) T.LLVMTypeRef {
    if (i == 0 and params.len > 0 and std.mem.eql(u8, params[0].name, "self") and params[0].type_annotation == null) {
        // Split at the LAST `::` — module-qualified struct names themselves
        // contain `::` (e.g. `std/mem.lls::Arena::deinit`).
        if (std.mem.lastIndexOf(u8, name, "::")) |idx| {
            const prefix = name[0..idx];
            if (lc.state.structs.contains(prefix)) return lc.ptrTy();
        }
    }
    return resolveParamType(lc, fn_decl, params[i]);
}

fn resolveParamType(lc: *LlvmContext, fn_decl: *const ast.FunctionDecl, param: ast.Param) T.LLVMTypeRef {
    if (param.type_annotation) |ann| {
        if (from_ast.typeAstToDisplay(ann, lc.state)) |opt| {
            if (opt) |d| return types_mod.resolveOrSlot(lc, d);
        } else |_| {}
    }
    // Unannotated: fall back to the typechecker's inferred type on the param
    // reference inside the body (std wrappers: `floor(a)` → `__floor(float)`
    // records `float` on `a`). i64 only as the last resort.
    if (paramNameType(lc, fn_decl, param.name)) |ty| return ty;
    return lc.i64Ty();
}

/// Scan `fn_decl.body` for the first primary referencing `name` whose recorded
/// type is concrete (non-unknown).
fn paramNameType(lc: *LlvmContext, fn_decl: *const ast.FunctionDecl, name: []const u8) ?T.LLVMTypeRef {
    var found: ?T.LLVMTypeRef = null;
    scanParamNode(lc, fn_decl.body, name, &found);
    return found;
}

fn scanParamNode(lc: *LlvmContext, node: *ast.Node, name: []const u8, found: *?T.LLVMTypeRef) void {
    if (found.* != null) return;
    switch (node.*) {
        .primary => |p| {
            if (p.kind == .identifier and std.mem.eql(u8, p.name, name)) {
                if (lc.state.type_of_results.get(node)) |t| {
                    if (!std.mem.eql(u8, layout.unwrapTypeName(t), "unknown")) {
                        found.* = types_mod.resolveOrSlot(lc, t);
                    }
                }
            }
        },
        .block => |b| for (b.statements) |st| scanParamNode(lc, st, name, found),
        .call => |c| {
            scanParamNode(lc, c.callee, name, found);
            for (c.args) |a| scanParamNode(lc, a, name, found);
        },
        .binary => |b| {
            scanParamNode(lc, b.left, name, found);
            scanParamNode(lc, b.right, name, found);
        },
        .unary => |u| scanParamNode(lc, u.arg, name, found),
        .if_expr => |i| {
            scanParamNode(lc, i.condition, name, found);
            scanParamNode(lc, i.body, name, found);
            if (i.else_body) |e| scanParamNode(lc, e, name, found);
        },
        .for_expr => |f| {
            scanParamNode(lc, f.expr, name, found);
            scanParamNode(lc, f.body, name, found);
        },
        .return_expr => |r| if (r.return_value) |v| scanParamNode(lc, v, name, found),
        .member => |m| {
            scanParamNode(lc, m.object, name, found);
            scanParamNode(lc, m.property, name, found);
        },
        .index => |ix| {
            scanParamNode(lc, ix.object, name, found);
            if (ix.index) |i| scanParamNode(lc, i, name, found);
            if (ix.end) |e| scanParamNode(lc, e, name, found);
        },
        .array_literal => |al| for (al.elements) |e| scanParamNode(lc, e, name, found),
        .struct_init => |si| {
            scanParamNode(lc, si.type_expr, name, found);
            for (si.fields) |fl| scanParamNode(lc, fl.value, name, found);
        },
        .assignment => |asg| {
            scanParamNode(lc, asg.left, name, found);
            scanParamNode(lc, asg.right, name, found);
        },
        .declaration => |d| scanParamNode(lc, d.value, name, found),
        else => {},
    }
}

fn resolveReturnType(lc: *LlvmContext, name: []const u8, fn_decl: *const ast.FunctionDecl) T.LLVMTypeRef {
    if (fn_decl.return_type) |rt| {
        if (from_ast.typeAstToDisplay(rt, lc.state)) |opt| {
            if (opt) |d| {
                if (std.mem.eql(u8, d, "void")) return lc.voidTy();
                return types_mod.resolveOrSlot(lc, d);
            }
        } else |_| {}
        return lc.i64Ty();
    }
    // Unannotated: use the typechecker's inferred return type (e.g. std
    // wrappers like `parseFloat(str) { return __parseFloat(str); }` → f64).
    if (lc.state.functions.get(name)) |def| {
        if (def.return_type) |rt| {
            if (std.mem.eql(u8, rt, "void")) return lc.voidTy();
            return types_mod.resolveOrSlot(lc, rt);
        }
    }
    return lc.i64Ty();
}

fn declareFunctionFromDef(lc: *LlvmContext, name: []const u8, def: state_mod.FunctionDef) CodegenError!void {
    if (def.node.* != .function_decl) return;
    try declareFunction(lc, name, &def.node.function_decl);
}

fn declareFunction(lc: *LlvmContext, name: []const u8, fn_decl: *const ast.FunctionDecl) CodegenError!void {
    if (lc.functions.contains(name)) return;

    const params: []ast.Param = switch (fn_decl.params.*) {
        .params => |p| p.params,
        else => &.{},
    };

    const param_types = try lc.allocator.alloc(T.LLVMTypeRef, params.len);
    defer lc.allocator.free(param_types);
    for (params, 0..) |param, i| {
        _ = param;
        param_types[i] = resolveSelfParamType(lc, name, fn_decl, params, i);
    }

    const ret_ty = resolveReturnType(lc, name, fn_decl);
    const fn_ty = C.LLVMFunctionType(ret_ty, if (params.len > 0) param_types.ptr else null, @intCast(params.len), 0);

    const name_z = try lc.allocator.dupeZ(u8, name);
    defer lc.allocator.free(name_z);
    const fn_val = C.LLVMAddFunction(lc.mod, name_z, fn_ty);
    const duped_name = try lc.allocator.dupe(u8, name);
    try lc.functions.put(duped_name, fn_val);
}

fn lowerFunctionFromDef(lc: *LlvmContext, name: []const u8, def: state_mod.FunctionDef) CodegenError!void {
    if (def.node.* != .function_decl) return;
    try lowerFunction(lc, name, &def.node.function_decl);
}

fn lowerFunction(lc: *LlvmContext, name: []const u8, fn_decl: *const ast.FunctionDecl) CodegenError!void {
    const fn_val = lc.functions.get(name) orelse return;

    // Already has a body?
    if (C.LLVMGetFirstBasicBlock(fn_val) != null) return;

    const entry = C.LLVMAppendBasicBlockInContext(lc.ctx, fn_val, "entry");
    C.LLVMPositionBuilderAtEnd(lc.builder, entry);

    var ss = stmt_mod.StmtState.init(lc, fn_val);
    defer ss.deinit();

    const params: []ast.Param = switch (fn_decl.params.*) {
        .params => |p| p.params,
        else => &.{},
    };
    for (params, 0..) |param, i| {
        const arg = C.LLVMGetParam(fn_val, @intCast(i));
        const name_z = try lc.allocator.dupeZ(u8, param.name);
        defer lc.allocator.free(name_z);
        C.LLVMSetValueName2(arg, name_z, param.name.len);
        const pty = resolveSelfParamType(lc, name, fn_decl, params, i);
        const slot = C.LLVMBuildAlloca(lc.builder, pty, name_z);
        _ = C.LLVMBuildStore(lc.builder, arg, slot);
        try ss.locals.put(param.name, slot);
    }

    try stmt_mod.lowerStmt(&ss, fn_decl.body);

    var current_bb = C.LLVMGetFirstBasicBlock(fn_val);
    while (current_bb != null) {
        if (C.LLVMGetBasicBlockTerminator(current_bb) == null) {
            C.LLVMPositionBuilderAtEnd(lc.builder, current_bb);
            const fn_ty = C.LLVMGlobalGetValueType(fn_val);
            const ret_ty = C.LLVMGetReturnType(fn_ty);
            if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) {
                _ = C.LLVMBuildRetVoid(lc.builder);
            } else {
                _ = C.LLVMBuildRet(lc.builder, C.LLVMConstNull(ret_ty));
            }
        }
        current_bb = C.LLVMGetNextBasicBlock(current_bb);
    }
}
