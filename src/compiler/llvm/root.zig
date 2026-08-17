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
const state_mod = @import("../state.zig");

pub const LlvmContext = context.LlvmContext;
pub const CodegenError = stmt_mod.StmtError || error{UnsupportedTopLevel};

/// Lower an entire parsed `Document` into LLVM IR stored in `lc`.
pub fn codegen(lc: *LlvmContext, doc: *ast.Document) CodegenError!void {
    // Data layout needed for @sizeOf / @new.
    _ = C.LLVMSetTarget(lc.mod, "x86_64-unknown-linux-gnu");

    // Declare every known function (free + Struct::method) with real ABI.
    var fit = lc.state.functions.iterator();
    while (fit.next()) |e| {
        const name = e.key_ptr.*;
        const def = e.value_ptr.*;
        try declareFunctionFromDef(lc, name, def);
    }

    // Also declare any top-level function_decl not yet in the map (defensive).
    for (doc.statements) |node| {
        if (node.* == .function_decl) try declareFunction(lc, node.function_decl.name, &node.function_decl);
        if (node.* == .struct_decl) {
            for (node.struct_decl.methods) |m| {
                if (m.* == .function_decl) {
                    var buf: [256]u8 = undefined;
                    const mangled = std.fmt.bufPrint(&buf, "{s}::{s}", .{ node.struct_decl.name, m.function_decl.name }) catch continue;
                    try declareFunction(lc, mangled, &m.function_decl);
                }
            }
        }
    }

    // Declare typed globals (null init; stores happen in __llts_main).
    try declareGlobals(lc);

    // Emit function bodies from CompilerState (covers methods + free funcs).
    var emitted = std.StringHashMap(void).init(lc.allocator);
    defer emitted.deinit();

    var fit2 = lc.state.functions.iterator();
    while (fit2.next()) |e| {
        const name = e.key_ptr.*;
        const def = e.value_ptr.*;
        if (emitted.contains(name)) continue;
        try emitted.put(name, {});
        std.debug.print("Lowering function {s}\n", .{name});
        try lowerFunctionFromDef(lc, name, def);
        std.debug.print("Done lowering function {s}\n", .{name});
    }

    for (doc.statements) |node| {
        if (node.* == .function_decl) {
            if (!emitted.contains(node.function_decl.name)) {
                try lowerFunction(lc, node.function_decl.name, &node.function_decl);
            }
        }
        if (node.* == .struct_decl) {
            for (node.struct_decl.methods) |m| {
                if (m.* != .function_decl) continue;
                var buf: [256]u8 = undefined;
                const mangled = std.fmt.bufPrint(&buf, "{s}::{s}", .{ node.struct_decl.name, m.function_decl.name }) catch continue;
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
        // Skip pure @import bindings (no runtime value we can lower yet).
        if (node.* == .declaration) {
            if (node.declaration.value.* == .call and
                node.declaration.value.call.callee.* == .primary and
                std.mem.eql(u8, node.declaration.value.call.callee.primary.name, "@import"))
            {
                continue;
            }
        }
        try stmt_mod.lowerStmt(&ss, node);
    }
    _ = C.LLVMBuildRetVoid(lc.builder);

    // Synthesize C main
    const c_main_ty = C.LLVMFunctionType(lc.i32Ty(), null, 0, 0);
    const c_main_val = C.LLVMAddFunction(lc.mod, "main", c_main_ty);
    const c_main_entry = C.LLVMAppendBasicBlockInContext(lc.ctx, c_main_val, "entry");
    C.LLVMPositionBuilderAtEnd(lc.builder, c_main_entry);

    _ = C.LLVMBuildCall2(lc.builder, llts_main_ty, llts_main_val, null, 0, "");

    if (lc.functions.get("main")) |user_main| {
        const user_main_ty = C.LLVMGlobalGetValueType(user_main);
        _ = C.LLVMBuildCall2(lc.builder, user_main_ty, user_main, null, 0, "");
    }

    _ = C.LLVMBuildRet(lc.builder, C.LLVMConstInt(lc.i32Ty(), 0, 0));
}

fn declareGlobals(lc: *LlvmContext) CodegenError!void {
    var g_it = lc.state.global_vars.iterator();
    while (g_it.next()) |entry| {
        const name = entry.key_ptr.*;
        try addGlobal(lc, name);
    }
    var c_it = lc.state.global_consts.iterator();
    while (c_it.next()) |entry| {
        const name = entry.key_ptr.*;
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

fn resolveParamType(lc: *LlvmContext, param: ast.Param) T.LLVMTypeRef {
    if (param.type_annotation) |ann| {
        if (from_ast.typeAstToDisplay(ann, lc.state)) |opt| {
            if (opt) |d| return types_mod.resolveOrSlot(lc, d);
        } else |_| {}
    }
    return lc.i64Ty();
}

fn resolveReturnType(lc: *LlvmContext, fn_decl: *const ast.FunctionDecl) T.LLVMTypeRef {
    if (fn_decl.return_type) |rt| {
        if (from_ast.typeAstToDisplay(rt, lc.state)) |opt| {
            if (opt) |d| {
                if (std.mem.eql(u8, d, "void")) return lc.voidTy();
                return types_mod.resolveOrSlot(lc, d);
            }
        } else |_| {}
        return lc.i64Ty();
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
        param_types[i] = resolveParamType(lc, param);
    }

    const ret_ty = resolveReturnType(lc, fn_decl);
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
        const pty = resolveParamType(lc, param);
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
